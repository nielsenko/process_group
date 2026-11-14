const std = @import("std");
const builtin = @import("builtin");

const c = std.c;
const linux = std.os.linux;

const program = "process_group_helper";

/// errno comes from libc where it is linked, which is always the case on
/// macOS, and from the raw syscalls on Linux otherwise.
const E = if (builtin.link_libc) c.E else linux.E;

// sysexits.h and the shell convention for a command that cannot run.
const exit_usage = 64;
const exit_os_error = 71;
const exit_not_executable = 126;
const exit_not_found = 127;

pub fn main(init: std.process.Init.Minimal) void {
    const args = init.args.vector;
    const session = args.len > 1 and
        std.mem.eql(u8, std.mem.span(args[1]), "--session");
    const command = args[if (session) 2 else @min(1, args.len)..];
    if (command.len == 0) {
        std.debug.print("usage: " ++ program ++ " [--session] <command> [argument...]\n", .{});
        std.process.exit(exit_usage);
    }
    if (session) newSession() else newProcessGroup();
    const envp: [*:null]const ?[*:0]const u8 = init.environ.block.slice.ptr;
    exec(std.mem.span(command[0]), nullTerminated(command), envp);
}

// libc declarations std.c leaves out.
const libc = struct {
    extern "c" fn getpgid(pid: c.pid_t) c.pid_t;
    extern "c" fn getsid(pid: c.pid_t) c.pid_t;
};

fn newProcessGroup() void {
    // A group leader has its own group already. setpgid refuses one that
    // leads a session too, as the helper does when Dart 3.14 starts it
    // detached on macOS.
    if (leadsProcessGroup()) return;
    const err = if (builtin.link_libc)
        c.errno(c.setpgid(0, 0))
    else
        linux.errno(linux.setpgid(0, 0));
    if (err != .SUCCESS) {
        std.debug.print(program ++ ": setpgid: {s}\n", .{@tagName(err)});
        std.process.exit(exit_os_error);
    }
}

/// Leaves this process leading a session, and with that a process group.
/// A session made here has no controlling terminal. One this process led
/// already keeps the terminal it has.
fn newSession() void {
    // setsid refuses a group leader. The helper is one, and a session
    // leader with it, when Dart 3.14 starts it detached on macOS.
    if (leadsSession()) return;
    const err = if (builtin.link_libc)
        c.errno(c.setsid())
    else
        linux.errno(linux.setsid());
    if (err != .SUCCESS) {
        std.debug.print(program ++ ": setsid: {s}\n", .{@tagName(err)});
        std.process.exit(exit_os_error);
    }
}

fn leadsSession() bool {
    if (builtin.link_libc) return libc.getsid(0) == c.getpid();
    return linux.getsid(0) == @as(usize, @intCast(linux.getpid()));
}

fn leadsProcessGroup() bool {
    if (builtin.link_libc) return libc.getpgid(0) == c.getpid();
    return linux.getpgid(0) == @as(usize, @intCast(linux.getpid()));
}

fn nullTerminated(args: []const [*:0]const u8) [*:null]const ?[*:0]const u8 {
    const argv = std.heap.page_allocator.allocSentinel(
        ?[*:0]const u8,
        args.len,
        null,
    ) catch {
        std.debug.print(program ++ ": out of memory\n", .{});
        std.process.exit(exit_os_error);
    };
    for (args, argv) |arg, *slot| slot.* = arg;
    return argv.ptr;
}

/// Becomes `command`, found on PATH unless it names a path, as execvp
/// would. Returns only by exiting, with the shell's codes for a command
/// that is missing or cannot run.
fn exec(
    command: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) noreturn {
    if (std.mem.indexOfScalar(u8, command, '/') != null) {
        fail(command, execve(command.ptr, argv, envp));
    }
    const path = getenv(envp, "PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var denied = false;
    var buffer: [4096]u8 = undefined;
    var directories = std.mem.splitScalar(u8, path, ':');
    while (directories.next()) |directory| {
        const dir = if (directory.len == 0) "." else directory;
        const candidate = std.fmt.bufPrintZ(&buffer, "{s}/{s}", .{ dir, command }) catch continue;
        switch (execve(candidate.ptr, argv, envp)) {
            .ACCES => denied = true,
            .NOENT, .NOTDIR => {},
            else => |err| fail(candidate, err),
        }
    }
    std.debug.print(program ++ ": {s}: {s}\n", .{
        command,
        if (denied) "permission denied" else "command not found",
    });
    std.process.exit(if (denied) exit_not_executable else exit_not_found);
}

fn execve(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) E {
    if (builtin.link_libc) return c.errno(c.execve(path, argv, envp));
    return linux.errno(linux.execve(path, argv, envp));
}

fn fail(path: []const u8, err: E) noreturn {
    std.debug.print(program ++ ": {s}: {s}\n", .{ path, @tagName(err) });
    std.process.exit(switch (err) {
        .NOENT, .NOTDIR => exit_not_found,
        else => exit_not_executable,
    });
}

fn getenv(envp: [*:null]const ?[*:0]const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const pair = std.mem.span(entry);
        if (pair.len > name.len and
            pair[name.len] == '=' and
            std.mem.eql(u8, pair[0..name.len], name))
        {
            return pair[name.len + 1 ..];
        }
    }
    return null;
}
