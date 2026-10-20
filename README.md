# leash

Starts a process on a leash: killing it ends every process it started.

`Process.kill` reaches one process. When that process is a wrapper, such as
a shell script or a version manager's launcher, the program behind it keeps
running: `bash` holds a SIGINT it received alone until its child exits, and
SIGKILL orphans the child. `Leash.start` takes what `Process.start` takes
and returns a `Process` whose `kill` reaches the whole tree.

```dart
import 'package:leash/leash.dart';

final process = await Leash.start('flutter', ['run', '--machine']);
// ...
process.kill(); // flutter, and everything it started
```

`Leash.start` has `Process.start`'s parameters except `runInShell`: the
helper looks the command up on PATH itself, and a shell would only add a
process to the tree. The result implements `Process`. On POSIX `pid` is the
command's own.

## How

A helper executable, `binary/<os>-<arch>/leash`, sits between Dart and the
command.

- POSIX: it calls `setpgid(0, 0)` and execs the command. The pid Dart got
  is the command's pid and its process group id, so `kill` signals `-pid`,
  which reaches every descendant still in the group.
- Windows: it creates a job object with the kill-on-close limit, starts the
  command suspended, assigns it to the job, resumes it and waits, exiting
  with the command's exit code. Ending the helper closes the handle, and
  the job ends every process in it. The command line is handed on as the
  caller quoted it.

## What it costs

- The command leaves the terminal's foreground process group, so Ctrl-C in
  the terminal no longer reaches it directly. The Dart program has to catch
  SIGINT and forward it with `kill(ProcessSignal.sigint)`.
- With `ProcessStartMode.inheritStdio` the command cannot read the
  terminal: a background process group that tries is stopped.
- A process that leaves on its own is not reached: `setsid` or a daemon
  fork on POSIX, `CREATE_BREAKAWAY_FROM_JOB` on Windows, which the job
  allows.
- On Windows `pid` is the helper's, and the exit code is forwarded.

## The helper

Built from `src/` with [zig_hook](../zig_hook) and shipped prebuilt under
`binary/` for macOS, Linux and Windows on x64 and arm64, and for arm and
riscv64 Linux. A checkout builds every target with
`dart run zig_hook:build_binaries`, or one with
`dart run zig_hook:build_binaries macos-arm64`. The tests build the host
target when it is missing.

A program with no package root at run time, such as one built with
`dart compile exe`, sets `LEASH_HELPER` to the executable's path.

The helper's own exit codes follow the shell: 127 when the command is not
found, 126 when it cannot run, 64 for a missing command, 71 for an OS
error before the command started.
