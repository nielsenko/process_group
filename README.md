# leashed_process

Starts a process on a leash: killing it ends every process it started.

`Process.kill` reaches one process. When that process is a wrapper, such as
a shell script or a version manager's launcher, the program behind it keeps
running: `bash` holds a SIGINT it received alone until its child exits, and
SIGKILL orphans the child. `LeashedProcess.start` takes what `Process.start`
takes and returns a `Process` whose `kill` reaches the whole tree.

```dart
import 'package:leashed_process/leashed_process.dart';

final process = await LeashedProcess.start('flutter', ['run', '--machine']);
// ...
process.kill(); // flutter, and everything it started
```

`LeashedProcess.start` has `Process.start`'s parameters except
`runInShell`: the helper looks the command up on PATH itself, and a shell
would only add a process to the tree. The result implements `Process`. On
POSIX `pid` is the command's own.

With `newSession: true` the command leads a session of its own as well.
That takes it off the program's terminal. The command and what it starts
cannot open `/dev/tty`, so a password prompt from `git` or `ssh` cannot
draw over a terminal UI. Windows has no such session, and the flag does
nothing there.

## What the command leaves behind

On POSIX the process group outlives the command for as long as a process
it started is still in it. `process.group` is that group:

```dart
final process = await LeashedProcess.start('dart', ['test']);
final code = await process.exitCode;
// A server that a test started and never stopped is still running.
await process.group?.stop(); // SIGTERM, then SIGKILL after two seconds
```

`process.killCommand()` signals the command alone and leaves the rest of
the group running. `group.exists` says whether a process is left in it.
The system may hand the id of an empty group to a new process, so stop a
group while it exists and then forget it.

On Windows `group` is null. The job ends with its command, so nothing is
left behind.

## How

A helper executable, `binary/<os>-<arch>/leashed_process_helper`, sits
between Dart and the command.

- POSIX: it calls `setpgid(0, 0)`, or `setsid()` for a new session, and
  execs the command. The pid Dart got is the command's pid and its process
  group id, so `kill` signals `-pid`, which reaches every descendant still
  in the group.
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
`dart compile exe`, ships the helper itself and passes its path to
`LeashedProcess.start` as `helperPath`. `LEASHED_PROCESS_HELPER` in the
environment names the helper from outside the program.

The helper's own exit codes follow the shell: 127 when the command is not
found, 126 when it cannot run, 64 for a missing command, 71 for an OS
error before the command started.
