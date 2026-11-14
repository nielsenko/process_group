# leashed_process

Starts a process on a leash, so that killing it ends every process it
started.

`Process.kill` reaches one process. When that process is a wrapper, such as
a shell script or a version manager's launcher, the program behind it keeps
running. `bash` holds a SIGINT it received alone until its child exits, and
SIGKILL orphans the child. `LeashedProcess.start` takes what `Process.start`
takes and returns a `Process` whose `kill` reaches the whole tree.

```dart
import 'package:leashed_process/leashed_process.dart';

final process = await LeashedProcess.start('flutter', ['run', '--machine']);
// ...
process.kill(); // flutter, and everything it started
```

`LeashedProcess.start` has `Process.start`'s parameters except
`runInShell`. The helper looks the command up on PATH itself, and a shell
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
  terminal. A background process group that tries is stopped.
- A process that leaves on its own is not reached. On POSIX a process
  leaves by calling `setsid` or `setpgid`. A daemon does that, and so does
  anything the leashed command starts through this package. On Windows a
  process leaves when it is started with `CREATE_BREAKAWAY_FROM_JOB`, which
  the job allows.
- On Windows `pid` is the helper's, and the exit code is forwarded.

## What Dart 3.14 changed on macOS

Dart 3.14 starts processes on macOS with `posix_spawn`, where 3.13 forked
and called `exec`. The
[changelog](https://github.com/dart-lang/sdk/blob/3.14.0/CHANGELOG.md)
gives it one entry under `dart:io`. Two things a program can see changed
with it. Linux did not change, going by its
[process_linux.cc](https://github.com/dart-lang/sdk/blob/3.14.0/runtime/bin/process_linux.cc),
which forks as before.

### A detached child

Before this package, a detached start was how a Dart program gave a child
a process group of its own. `ProcessStartMode.detached` and
`detachedWithStdio` both do it, at the price of the exit code. This is what
such a child looks like on macOS, measured with Dart 3.13.7 and 3.14.0:

| A detached child  | Dart 3.13          | Dart 3.14        |
| ----------------- | ------------------ | ---------------- |
| Its parent        | pid 1              | the Dart program |
| Its process group | a pid that is gone | its own pid      |
| Leads a session   | no                 | yes              |
| After it exits    | gone at once       | a zombie         |

Up to 3.13 the SDK forks, calls `setsid` in the child and forks again, and
the second child becomes the program
([process_macos.cc](https://github.com/dart-lang/sdk/blob/3.13.7/runtime/bin/process_macos.cc),
`ExecDetachedProcess`). The process in the middle exits. That hands the
program to pid 1, which collects it the moment it ends. The program's
group id is the pid of the process in the middle, and only `getpgid` can
tell what it is.

From 3.14 the SDK makes one `posix_spawn` call with `POSIX_SPAWN_SETSID`
([process_macos.cc](https://github.com/dart-lang/sdk/blob/3.14.0/runtime/bin/process_macos.cc),
`Spawn`). The program is a direct child and leads its session. Dart waits
only for the children it started attached, so nobody collects a detached
one. Each stays in the process table as a zombie until the Dart program
exits, and `kill(pid, 0)` keeps reporting it alive. A program that starts
many short-lived detached children collects one zombie for each.

`LeashedProcess.start` needs no detached mode. In the normal mode the
command leads its group on every Dart version, Dart collects it when it
exits, and `exitCode` works. `newSession: true` adds the session a detached
start gave. One thing differs from a detached start. Dart stays alive while
a command started in the normal mode runs, so a program that is done has to
stop the command or call `exit`.

The helper can still be started detached. From 3.14 on macOS it then leads
a session before it has run a line, and the system refuses `setpgid` and
`setsid` to a session leader. The helper sees that it leads already and
calls neither.

### The PATH a command is found on

`Process.start` with a bare command name and an `environment` used to look
the command up on the `PATH` of that environment. From 3.14 on macOS it
looks on the `PATH` of the Dart program. Measured with a tool that is only
on the child's `PATH`:

| Started with           | Dart 3.13.7 | Dart 3.14.0               |
| ---------------------- | ----------- | ------------------------- |
| `Process.start`        | found       | No such file or directory |
| `LeashedProcess.start` | found       | found                     |

The helper is started by its full path, and it looks the command up itself
on the `PATH` it was given. So a leashed command is found on the `PATH` of
its own environment on every platform and Dart version.

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

The helper's own exit codes follow the shell. It exits with 127 when the
command is not found, 126 when it cannot run, 64 for a missing command and
71 for an OS error before the command started.
