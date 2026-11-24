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

const usage =
    "usage: " ++ program ++ " [--session] <command> [argument...]\n" ++
    "       " ++ program ++ " --keeper <file>\n";

pub fn main(init: std.process.Init.Minimal) void {
    const args = init.args.vector;
    if (args.len > 1 and std.mem.eql(u8, std.mem.span(args[1]), "--keeper")) {
        if (args.len != 3) {
            std.debug.print(usage, .{});
            std.process.exit(exit_usage);
        }
        keep(args[2]);
    }
    const session = args.len > 1 and
        std.mem.eql(u8, std.mem.span(args[1]), "--session");
    const command = args[if (session) 2 else @min(1, args.len)..];
    if (command.len == 0) {
        std.debug.print(usage, .{});
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
    // std.c takes the signal as an enum, which has no member for 0.
    extern "c" fn kill(pid: c.pid_t, signal: c_int) c_int;
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

/// Takes the keeper out of the process group of the program that started
/// it, so that a signal to that group does not end the keeper with it.
/// Dart starts it detached, which leaves it leading a session already.
fn leaveProcessGroup() void {
    if (leadsSession() or leadsProcessGroup()) return;
    if (builtin.link_libc) _ = c.setsid() else _ = linux.setsid();
}

fn leadsSession() bool {
    if (builtin.link_libc) return libc.getsid(0) == c.getpid();
    return linux.getsid(0) == @as(usize, @intCast(linux.getpid()));
}

fn leadsProcessGroup() bool {
    if (builtin.link_libc) return libc.getpgid(0) == c.getpid();
    return linux.getpgid(0) == @as(usize, @intCast(linux.getpid()));
}

// How often the keeper looks at the lock and reads the file, and how many
// of those looks pass between two checks for groups that emptied.
const keeper_tick_ms = 200;
const keeper_ticks_per_check = 5;

// How many of those checks may find no process in a group the keeper has
// not seen yet, before it gives the group up.
const unseen_checks = 5;

// What a group gets between SIGTERM and SIGKILL, and how often the keeper
// looks whether it emptied meanwhile.
const stop_grace_ms = 2000;
const stop_poll_ms = 50;

const sigterm = 15;
const sigkill = 9;

/// Stops the process groups named in the file at `path` once the program
/// that holds the file locked is gone, then removes the file and exits.
///
/// The program appends a line for each group, `+<id>` to add it and
/// `-<id>` to forget it. It holds a lock on the file for as long as it
/// lives, and the system releases that lock however the program ends.
fn keep(path: [*:0]const u8) noreturn {
    leaveProcessGroup();
    const fd = openReadWrite(path) orelse {
        std.debug.print(program ++ ": cannot open {s}\n", .{path});
        std.process.exit(exit_os_error);
    };
    var groups: Groups = .{};
    var lines: Lines = .{ .fd = fd };
    var tick: usize = 0;
    while (!lockGranted(fd)) : (tick += 1) {
        lines.readInto(&groups);
        if (tick % keeper_ticks_per_check == 0) groups.forgetEmptied();
        sleepMs(keeper_tick_ms);
    }
    lines.readInto(&groups);
    groups.stop();
    removeWithDirectory(path);
    std.process.exit(0);
}

/// The process groups the keeper is to stop.
///
/// A group does not exist until the helper that leads it has run, which
/// is a moment after the program wrote its id. So a group counts as
/// emptied only once the keeper has found it there, and one it never
/// finds is forgotten after `unseen_checks` looks.
const Groups = struct {
    entries: []Entry = &[_]Entry{},
    count: usize = 0,

    const Entry = struct {
        id: i32,
        /// Whether the keeper has found a process in the group.
        seen: bool = false,
        /// The looks that found no process in it, while it is unseen.
        unseen: u8 = 0,
        /// Whether `stop` has sent it SIGTERM.
        signalled: bool = false,
    };

    fn exists(id: i32) bool {
        return kill(-id, 0) == .SUCCESS;
    }

    fn indexOf(self: *const Groups, id: i32) ?usize {
        for (self.entries[0..self.count], 0..) |entry, i| {
            if (entry.id == id) return i;
        }
        return null;
    }

    fn removeAt(self: *Groups, i: usize) void {
        self.count -= 1;
        self.entries[i] = self.entries[self.count];
    }

    fn add(self: *Groups, id: i32) void {
        if (self.indexOf(id) != null) return;
        if (self.count == self.entries.len) {
            self.entries = std.heap.page_allocator.realloc(
                self.entries,
                @max(16, self.entries.len * 2),
            ) catch {
                std.debug.print(program ++ ": out of memory\n", .{});
                std.process.exit(exit_os_error);
            };
        }
        self.entries[self.count] = .{ .id = id };
        self.count += 1;
    }

    fn forget(self: *Groups, id: i32) void {
        if (self.indexOf(id)) |i| self.removeAt(i);
    }

    /// Forgets every group that emptied, because the system may give the
    /// id of an empty group to a new process.
    fn forgetEmptied(self: *Groups) void {
        var i: usize = 0;
        while (i < self.count) {
            const entry = &self.entries[i];
            if (exists(entry.id)) {
                entry.seen = true;
            } else if (entry.seen or entry.unseen >= unseen_checks) {
                self.removeAt(i);
                continue;
            } else {
                entry.unseen += 1;
            }
            i += 1;
        }
    }

    /// Sends SIGTERM to every group, and SIGKILL to what is left in them
    /// once the grace is over. A group that comes to exist during the
    /// grace gets its SIGTERM then.
    fn stop(self: *Groups) void {
        var waited: usize = 0;
        while (true) : (waited += stop_poll_ms) {
            var i: usize = 0;
            while (i < self.count) {
                const entry = &self.entries[i];
                if (exists(entry.id)) {
                    entry.seen = true;
                    if (!entry.signalled) _ = kill(-entry.id, sigterm);
                    entry.signalled = true;
                } else if (entry.seen) {
                    self.removeAt(i);
                    continue;
                }
                i += 1;
            }
            if (self.count == 0 or waited >= stop_grace_ms) break;
            sleepMs(stop_poll_ms);
        }
        for (self.entries[0..self.count]) |entry| _ = kill(-entry.id, sigkill);
    }
};

/// Reads the lines appended to the keeper's file since the last read.
const Lines = struct {
    fd: i32,
    offset: u64 = 0,
    /// The start of a line whose end is not written yet. No line the
    /// program writes is longer than this.
    line: [16]u8 = undefined,
    length: usize = 0,

    fn readInto(self: *Lines, groups: *Groups) void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const read = pread(self.fd, &buffer, self.offset);
            if (read == 0) return;
            self.offset += read;
            for (buffer[0..read]) |byte| {
                if (byte == '\n') {
                    if (self.length <= self.line.len) {
                        apply(self.line[0..self.length], groups);
                    }
                    self.length = 0;
                } else {
                    if (self.length < self.line.len) self.line[self.length] = byte;
                    self.length += 1;
                }
            }
        }
    }

    fn apply(line: []const u8, groups: *Groups) void {
        if (line.len < 2) return;
        const id = std.fmt.parseInt(i32, line[1..], 10) catch return;
        // A signal to group 0 goes to the keeper's own group, and one to
        // group 1 to every process it may signal.
        if (id < 2) return;
        switch (line[0]) {
            '+' => groups.add(id),
            '-' => groups.forget(id),
            else => {},
        }
    }
};

fn openReadWrite(path: [*:0]const u8) ?i32 {
    // A write lock needs a descriptor that is open for writing.
    if (builtin.link_libc) {
        const fd = c.open(path, c.O{ .ACCMODE = .RDWR });
        return if (fd < 0) null else fd;
    }
    const result = linux.open(path, .{ .ACCMODE = .RDWR }, 0);
    return if (linux.errno(result) == .SUCCESS) @intCast(result) else null;
}

/// Whether the lock on the whole file went to this process, which it does
/// once the program that held it is gone. A record lock, as Dart's
/// `RandomAccessFile.lock` takes, so it is the process that holds it and
/// not a descriptor a child may have inherited.
fn lockGranted(fd: i32) bool {
    if (builtin.os.tag == .linux) {
        var lock = std.mem.zeroes(linux.Flock);
        lock.type = linux.F.WRLCK;
        const err = linux.errno(linux.fcntl(fd, linux.F.SETLK, @intFromPtr(&lock)));
        return lockAnswer(err == .SUCCESS, err == .AGAIN or err == .ACCES, @tagName(err));
    } else {
        var lock = std.mem.zeroes(c.Flock);
        lock.type = c.F.WRLCK;
        const err = c.errno(c.fcntl(fd, c.F.SETLK, &lock));
        return lockAnswer(err == .SUCCESS, err == .AGAIN or err == .ACCES, @tagName(err));
    }
}

/// What an attempt at the lock says: true when it was granted, false when
/// another process holds it. Any other answer ends the keeper, which then
/// has no way to learn that the program is gone.
fn lockAnswer(granted: bool, held: bool, err: []const u8) bool {
    if (granted) return true;
    if (held) return false;
    std.debug.print(program ++ ": lock: {s}\n", .{err});
    std.process.exit(exit_os_error);
}

/// The bytes read into `buffer` from `offset`, none at the end of the
/// file or on an error.
fn pread(fd: i32, buffer: []u8, offset: u64) usize {
    if (builtin.link_libc) {
        const read = c.pread(fd, buffer.ptr, buffer.len, @intCast(offset));
        return if (read < 0) 0 else @intCast(read);
    }
    const result = linux.pread(fd, buffer.ptr, buffer.len, @intCast(offset));
    return if (linux.errno(result) == .SUCCESS) result else 0;
}

/// kill(2) with the signal as a number. Signal 0 sends nothing and tells
/// whether there is a process to signal.
fn kill(pid: i32, signal: u8) E {
    if (builtin.link_libc) return c.errno(libc.kill(pid, signal));
    return linux.errno(linux.syscall2(
        .kill,
        @bitCast(@as(isize, pid)),
        signal,
    ));
}

fn sleepMs(ms: u32) void {
    if (builtin.link_libc) {
        const time: c.timespec = .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast(@as(u64, ms % 1000) * 1_000_000),
        };
        _ = c.nanosleep(&time, null);
    } else {
        const time: linux.timespec = .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast(@as(u64, ms % 1000) * 1_000_000),
        };
        _ = linux.nanosleep(&time, null);
    }
}

/// Removes the file at `path` and the directory it is in, when that is
/// empty then.
fn removeWithDirectory(path: [*:0]const u8) void {
    const file = std.mem.span(path);
    if (builtin.link_libc) _ = c.unlink(path) else _ = linux.unlink(path);
    const slash = std.mem.lastIndexOfScalar(u8, file, '/') orelse return;
    var buffer: [4096]u8 = undefined;
    const directory = std.mem.printSentinel(&buffer, "{s}", .{file[0..slash]}, 0) catch return;
    if (builtin.link_libc) _ = c.rmdir(directory.ptr) else _ = linux.rmdir(directory.ptr);
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
        const candidate = std.mem.printSentinel(&buffer, "{s}/{s}", .{ dir, command }, 0) catch continue;
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
