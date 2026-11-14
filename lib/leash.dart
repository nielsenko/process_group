/// Starts a process on a leash: killing it ends every process it started.
///
/// [Leash.start] takes what [Process.start] takes and returns a [Process]
/// whose [Process.kill] reaches the whole tree. A small helper executable,
/// shipped under `binary/` per platform, does the work: on POSIX it moves
/// into a new process group and becomes the command, on Windows it owns a
/// job object that dies with it.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

/// A process started by [Leash.start].
final class LeashedProcess implements Process {
  LeashedProcess._(this._process)
    : group = Platform.isWindows ? null : LeashGroup(_process.pid);

  final Process _process;

  /// The process group of the command, which outlives the command for as
  /// long as a process it started is left in it.
  ///
  /// Null on Windows, where the job ends with its command and nothing is
  /// left behind.
  final LeashGroup? group;

  /// On POSIX the command's own pid, which is also its process group id.
  /// On Windows the pid of the leash helper that owns the job object.
  @override
  int get pid => _process.pid;

  /// The command's exit code. A command that a signal ended reports the
  /// negated signal number, as [Process.exitCode] does. The helper's own
  /// failures use the shell's codes: 127 for a command that was not found,
  /// 126 for one that could not run.
  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  IOSink get stdin => _process.stdin;

  /// Sends [signal] to the command and every process it started that is
  /// still in its process group. On Windows every signal terminates the
  /// job object and all of its processes.
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

/// The process group of a leashed command, which holds the command and
/// every process it started that has not left the group.
///
/// POSIX only. The group outlives the command for as long as one process
/// is left in it, so a caller can let those processes run on and [stop]
/// them later.
final class LeashGroup {
  /// The group with the process group id [id].
  LeashGroup(this.id);

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

/// The leash helper for this platform cannot be found.
final class LeashHelperMissing implements Exception {
  LeashHelperMissing(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract final class Leash {
  /// Starts [executable] with [arguments] on a leash.
  ///
  /// The parameters are those of [Process.start] without `runInShell`:
  /// the helper looks [executable] up on PATH itself, and a shell would
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
  /// Throws [LeashHelperMissing] when the helper for this platform is not
  /// available, see [helper].
  static Future<LeashedProcess> start(
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
    return LeashedProcess._(process);
  }

  /// The environment variable that names the helper executable from
  /// outside a program with no package root at run time, such as one built
  /// with `dart compile exe`.
  static const helperVariable = 'LEASH_HELPER';

  /// The helper executable for this platform: [helperVariable] when set,
  /// else `binary/<os>-<arch>/leash` under this package.
  ///
  /// A checkout has no `binary/` until `dart run zig_hook:build_binaries`
  /// has run.
  static Future<String> helper() async {
    final override = Platform.environment[helperVariable];
    if (override != null) return override;
    if (_helper case final found?) return found;

    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:leash/leash.dart'),
    );
    if (library == null) {
      throw LeashHelperMissing(
        'package:leash does not resolve to a directory, so its binary/ '
        'cannot be found. Pass helperPath to Leash.start, or set '
        '$helperVariable to the leash executable.',
      );
    }
    final directory = Abi.current().toString().replaceAll('_', '-');
    final name = Platform.isWindows ? 'leash.exe' : 'leash';
    final path = library.resolve('../binary/$directory/$name').toFilePath();
    if (!File(path).existsSync()) {
      throw LeashHelperMissing(
        'No leash helper for $directory at $path. In a checkout, run '
        '`dart run zig_hook:build_binaries $directory`. Otherwise pass '
        'helperPath to Leash.start, or set $helperVariable to the leash '
        'executable.',
      );
    }
    return _helper = path;
  }

  static String? _helper;
}
