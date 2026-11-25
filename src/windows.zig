const std = @import("std");
const w = std.os.windows;

const program = "process_group_helper";

const exit_usage = 64;
const exit_os_error = 71;
const exit_not_found = 127;

// kernel32 declarations std.os.windows leaves out.
extern "kernel32" fn CreateJobObjectW(
    attributes: ?*w.SECURITY_ATTRIBUTES,
    name: ?w.LPCWSTR,
) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn SetInformationJobObject(
    job: w.HANDLE,
    class: c_int,
    info: *const anyopaque,
    length: w.DWORD,
) callconv(.winapi) w.BOOL;
extern "kernel32" fn AssignProcessToJobObject(
    job: w.HANDLE,
    process: w.HANDLE,
) callconv(.winapi) w.BOOL;
extern "kernel32" fn TerminateProcess(
    process: w.HANDLE,
    exit_code: c_uint,
) callconv(.winapi) w.BOOL;
extern "kernel32" fn ResumeThread(thread: w.HANDLE) callconv(.winapi) w.DWORD;
extern "kernel32" fn WaitForSingleObject(
    handle: w.HANDLE,
    milliseconds: w.DWORD,
) callconv(.winapi) w.DWORD;
extern "kernel32" fn GetExitCodeProcess(
    process: w.HANDLE,
    exit_code: *w.DWORD,
) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetStdHandle(id: w.DWORD) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn ExitProcess(code: c_uint) callconv(.winapi) noreturn;

const STD_INPUT_HANDLE: w.DWORD = 0xFFFFFFF6;
const STD_OUTPUT_HANDLE: w.DWORD = 0xFFFFFFF5;
const STD_ERROR_HANDLE: w.DWORD = 0xFFFFFFF4;
const INFINITE: w.DWORD = 0xFFFFFFFF;

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: w.DWORD,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: w.DWORD,
    Affinity: usize,
    PriorityClass: w.DWORD,
    SchedulingClass: w.DWORD,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

const JobObjectExtendedLimitInformation: c_int = 9;
const JOB_OBJECT_LIMIT_BREAKAWAY_OK: w.DWORD = 0x800;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: w.DWORD = 0x2000;

pub fn main(init: std.process.Init.Minimal) void {
    // The raw command line, handed on past the helper's own name so the
    // command sees exactly the quoting its caller wrote.
    const line = afterFirstArgument(init.args.vector);
    if (line.len == 0) {
        std.debug.print("usage: " ++ program ++ " <command> [argument...]\n", .{});
        std.process.exit(exit_usage);
    }
    const command = std.heap.page_allocator.allocSentinel(u16, line.len, 0) catch {
        std.debug.print(program ++ ": out of memory\n", .{});
        std.process.exit(exit_os_error);
    };
    @memcpy(command, line);

    const job = CreateJobObjectW(null, null) orelse fail("CreateJobObject");
    var limits = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    // Kill on close takes the tree with the helper. Without breakaway a
    // process that asks for CREATE_BREAKAWAY_FROM_JOB fails to start. With
    // it the process leaves the job, as one that calls setsid leaves the
    // group on POSIX.
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
    if (!succeeded(SetInformationJobObject(
        job,
        JobObjectExtendedLimitInformation,
        &limits,
        @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
    ))) fail("SetInformationJobObject");

    var startup = std.mem.zeroes(w.STARTUPINFOW);
    startup.cb = @sizeOf(w.STARTUPINFOW);
    startup.dwFlags = w.STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    var info: w.PROCESS.INFORMATION = undefined;
    // Suspended until it is in the job, so that nothing it starts first
    // escapes.
    if (!succeeded(w.kernel32.CreateProcessW(
        null,
        command.ptr,
        null,
        null,
        .TRUE,
        .{ .create_suspended = true },
        null,
        null,
        &startup,
        &info,
    ))) {
        std.debug.print(program ++ ": CreateProcess: {s}\n", .{@tagName(w.GetLastError())});
        std.process.exit(exit_not_found);
    }
    if (!succeeded(AssignProcessToJobObject(job, info.hProcess))) {
        _ = TerminateProcess(info.hProcess, exit_os_error);
        fail("AssignProcessToJobObject");
    }
    _ = ResumeThread(info.hThread);
    w.CloseHandle(info.hThread);

    _ = WaitForSingleObject(info.hProcess, INFINITE);
    var code: w.DWORD = exit_os_error;
    _ = GetExitCodeProcess(info.hProcess, &code);
    ExitProcess(code);
}

fn succeeded(result: w.BOOL) bool {
    return @backingInt(result) != 0;
}

fn fail(call: []const u8) noreturn {
    std.debug.print(program ++ ": {s}: {s}\n", .{ call, @tagName(w.GetLastError()) });
    std.process.exit(exit_os_error);
}

/// The command line past its first argument, which may be quoted, and the
/// blanks after it.
fn afterFirstArgument(line: []const u16) []const u16 {
    var i: usize = 0;
    while (i < line.len and isBlank(line[i])) i += 1;
    if (i < line.len and line[i] == '"') {
        i += 1;
        while (i < line.len and line[i] != '"') i += 1;
        if (i < line.len) i += 1;
    } else {
        while (i < line.len and !isBlank(line[i])) i += 1;
    }
    while (i < line.len and isBlank(line[i])) i += 1;
    return line[i..];
}

fn isBlank(unit: u16) bool {
    return unit == ' ' or unit == '\t';
}

test afterFirstArgument {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqualSlices(u16, L("a b"), afterFirstArgument(L("helper a b")));
    try std.testing.expectEqualSlices(u16, L("a  b"), afterFirstArgument(L("\"C:\\x y\\helper.exe\"  a  b")));
    try std.testing.expectEqualSlices(u16, L(""), afterFirstArgument(L("helper")));
    try std.testing.expectEqualSlices(u16, L(""), afterFirstArgument(L("")));
}
