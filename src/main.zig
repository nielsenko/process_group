//! process_group_helper runs a command so that killing it ends every
//! process the command started.
//!
//! On POSIX it moves into a new process group and becomes the command, so
//! the pid its parent knows is both the command's pid and the group id,
//! and kill(-pid) reaches every descendant that stays in the group. With
//! --session it starts a session instead, which also leaves the command
//! without a controlling terminal.
//!
//! With --keeper <file> it is a keeper instead, on POSIX only. A program
//! appends the ids of process groups to the file and holds a lock on it.
//! The keeper waits for that lock to be free, which says the program is
//! gone, then stops every group the file names and removes the file.
//!
//! On Windows it creates a job object that ends its processes when its last
//! handle closes, starts the command suspended inside it, resumes it and
//! waits, exiting with the command's exit code. Terminating the helper
//! closes the handle and takes the tree with it.
const builtin = @import("builtin");

const impl = if (builtin.os.tag == .windows)
    @import("windows.zig")
else
    @import("posix.zig");

pub const main = impl.main;
