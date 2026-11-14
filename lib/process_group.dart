/// Processes in a process group of their own, where killing one ends
/// every process it started.
///
/// [GroupedProcess.start] takes what [Process.start] takes and returns a
/// [Process] whose [Process.kill] reaches the whole tree. A small helper
/// executable, shipped under `binary/` per platform, does the work. On
/// POSIX it moves into a new process group and becomes the command. On
/// Windows it owns a job object that dies with it.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

/// A process that [start] put in a process group of its own, so that
/// [kill] reaches every process it started.
final class GroupedProcess implements Process {
  GroupedProcess._(this._process)
    : group = Platform.isWindows ? null : ProcessGroup(_process.pid);

  /// Starts [executable] with [arguments] in a process group of its own.
  ///
  /// The parameters are those of [Process.start] without `runInShell`.
  /// The helper looks [executable] up on PATH itself, and a shell would
  /// only add a process to the tree. [workingDirectory] and the
  /// environment reach the command as they would from [Process.start].
  ///
  /// With [newSession] the command leads a session of its own as well,
  /// which takes it off this program's terminal. Neither the command nor
  /// what it starts can open `/dev/tty`, to prompt on it or to draw on it.
  /// Windows has no such session, and [newSession] does nothing there.
  ///
  /// [helperPath] names the helper executable to start, in place of the
  /// one [helper] finds. A program that ships its own copy passes it.
  ///
  /// Throws [ProcessGroupHelperMissing] when the helper for this platform
  /// is not available, see [helper].
  static Future<GroupedProcess> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    ProcessStartMode mode = ProcessStartMode.normal,
    bool newSession = false,
    String? helperPath,
  }) async {
    final process = await Process.start(
      helperPath ?? await helper(),
      [
        if (newSession && !Platform.isWindows) '--session',
        executable,
        ...arguments,
      ],
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      mode: mode,
    );
    return GroupedProcess._(process);
  }

  /// The environment variable that names the helper executable from
  /// outside a program with no package root at run time, such as one built
  /// with `dart compile exe`.
  static const helperVariable = 'PROCESS_GROUP_HELPER';

  /// The path of the helper executable for this platform.
  ///
  /// [helperVariable] names it when set. Otherwise it is
  /// `binary/<os>-<arch>/process_group_helper` under this package. A
  /// checkout has no `binary/` until `dart run zig_hook:build_binaries`
  /// has run.
  static Future<String> helper() async {
    final override = Platform.environment[helperVariable];
    if (override != null) return override;
    if (_helper case final found?) return found;

    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:process_group/process_group.dart'),
    );
    if (library == null) {
      throw ProcessGroupHelperMissing(
        'package:process_group does not resolve to a directory, so its '
        'binary/ cannot be found. Pass helperPath to GroupedProcess.start, '
        'or set $helperVariable to the helper executable.',
      );
    }
    final directory = Abi.current().toString().replaceAll('_', '-');
    const stem = 'process_group_helper';
    final name = Platform.isWindows ? '$stem.exe' : stem;
    final path = library.resolve('../binary/$directory/$name').toFilePath();
    if (!File(path).existsSync()) {
      throw ProcessGroupHelperMissing(
        'No helper for $directory at $path. In a checkout, run '
        '`dart run zig_hook:build_binaries $directory`. Otherwise pass '
        'helperPath to GroupedProcess.start, or set $helperVariable to '
        'the helper executable.',
      );
    }
    return _helper = path;
  }

  static String? _helper;

  final Process _process;

  /// The process group of the command, which outlives the command for as
  /// long as a process it started is left in it.
  ///
  /// Null on Windows, where the job ends with its command and nothing is
  /// left behind.
  final ProcessGroup? group;

  /// The pid of the command, which is also its process group id.
  ///
  /// On Windows it is the pid of the helper that owns the job object.
  @override
  int get pid => _process.pid;

  /// A future that completes with the command's exit code.
  ///
  /// A command that a signal ended reports the negated signal number, as
  /// [Process.exitCode] does. The helper's own failures use the shell's
  /// codes, 127 for a command that was not found and 126 for one that
  /// could not run.
  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  IOSink get stdin => _process.stdin;

  /// Sends [signal] to the command and to every process it started that
  /// is still in its process group.
  ///
  /// On Windows every signal terminates the job object and all of its
  /// processes.
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      group?.kill(signal) ?? _process.kill(signal);

  /// Sends [signal] to the command alone, which leaves what it started
  /// running in [group].
  ///
  /// On Windows the job ends with its command, so this does what [kill]
  /// does.
  bool killCommand([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _process.kill(signal);
}

/// The process group of a command, which holds the command and every
/// process it started that has not left the group.
///
/// POSIX only. The group outlives the command for as long as one process
/// is left in it, so a caller can let those processes run on and [stop]
/// them later.
final class ProcessGroup {
  /// The group with the process group id [id].
  ///
  /// Throws an [ArgumentError] when [id] is below 2. A signal to group 0
  /// goes to the caller's own group, and one to group 1 goes to every
  /// process the caller may signal.
  ProcessGroup(this.id) {
    if (id < 2) {
      throw ArgumentError.value(id, 'id', 'No command leads this group');
    }
  }

  /// The process group id, which is the pid of the command that leads the
  /// group.
  final int id;

  /// Whether a process is left in this group.
  ///
  /// An empty group is gone, and the system may hand its id to a new
  /// process. Forget a group that no longer exists, since a later [kill]
  /// could reach a stranger. A group this process may not signal counts as
  /// gone too.
  bool get exists => _kill(-id, 0) == 0;

  /// Sends [signal] to every process in this group.
  ///
  /// Returns false when no process is left in it.
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      Process.killPid(-id, signal);

  /// Sends SIGTERM to every process in this group, and SIGKILL to whatever
  /// is left in it after [grace].
  ///
  /// The future completes when the group is empty or the SIGKILL is sent,
  /// whichever comes first.
  Future<void> stop({Duration grace = const Duration(seconds: 2)}) async {
    if (!kill()) return;
    final waited = Stopwatch()..start();
    while (exists) {
      if (waited.elapsed >= grace) {
        kill(ProcessSignal.sigkill);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

final _kill = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'kill',
    );

/// The exception [GroupedProcess.start] throws when it finds no helper
/// for this platform.
final class ProcessGroupHelperMissing implements Exception {
  ProcessGroupHelperMissing(this.message);

  final String message;

  @override
  String toString() => message;
}
