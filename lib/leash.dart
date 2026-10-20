/// Starts a process on a leash: killing it ends every process it started.
///
/// [Leash.start] takes what [Process.start] takes and returns a [Process]
/// whose [Process.kill] reaches the whole tree. A small helper executable,
/// shipped under `binary/` per platform, does the work: on POSIX it moves
/// into a new process group and becomes the command, on Windows it owns a
/// job object that dies with it.
library;

import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

/// A process started by [Leash.start].
final class LeashedProcess implements Process {
  LeashedProcess._(this._process);

  final Process _process;

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
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (Platform.isWindows) return _process.kill(signal);
    return Process.killPid(-_process.pid, signal);
  }
}

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
  /// Throws [LeashHelperMissing] when the helper for this platform is not
  /// available, see [helper].
  static Future<LeashedProcess> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final process = await Process.start(
      await helper(),
      [executable, ...arguments],
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      mode: mode,
    );
    return LeashedProcess._(process);
  }

  /// Names the helper executable in the environment, for a program that
  /// has no package root at run time, such as one built with
  /// `dart compile exe`.
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
        'cannot be found. Set $helperVariable to the leash executable.',
      );
    }
    final directory = Abi.current().toString().replaceAll('_', '-');
    final name = Platform.isWindows ? 'leash.exe' : 'leash';
    final path = library.resolve('../binary/$directory/$name').toFilePath();
    if (!File(path).existsSync()) {
      throw LeashHelperMissing(
        'No leash helper for $directory at $path. In a checkout, run '
        '`dart run zig_hook:build_binaries $directory`. Otherwise set '
        '$helperVariable to the leash executable.',
      );
    }
    return _helper = path;
  }

  static String? _helper;
}
