import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:process_group/process_group.dart';
import 'package:test/test.dart';

/// Pids of every process in the group [pgid], from `ps`, which BSD and
/// procps spell the same way for these flags.
Future<Set<int>> processGroup(int pgid) async {
  final result = await Process.run('ps', ['-A', '-o', 'pid=,pgid=']);
  return {
    for (final line in LineSplitter.split(result.stdout as String))
      if (line.trim().split(spaces) case [final pid, final group]
          when int.parse(group) == pgid)
        int.parse(pid),
  };
}

/// Whether a process with [pid] is running, according to `tasklist`.
Future<bool> windowsProcessExists(int pid) async {
  final result = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
  return !(result.stdout as String).contains('No tasks');
}

final spaces = RegExp(r'\s+');

/// Waits up to two seconds for [group] to empty.
Future<void> emptied(ProcessGroup group) async {
  final waited = Stopwatch()..start();
  while (group.exists && waited.elapsed < const Duration(seconds: 2)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<String> text(Stream<List<int>> stream) =>
    stream.transform(utf8.decoder).join();

/// A command for the host's shell, which is `sh -c` on POSIX and
/// PowerShell on Windows.
List<String> shell(String posix, String windows) => Platform.isWindows
    ? ['powershell', '-NoProfile', '-Command', windows]
    : ['sh', '-c', posix];

/// A file this test holds locked and a keeper started on it, as
/// [GroupedProcess.start] sets them up for a program that asks for
/// `stopWithParent`.
///
/// Closing the file releases the lock, which is what the end of the
/// program does.
Future<({RandomAccessFile groups, Process keeper, File file})>
startKeeper() async {
  final dir = await Directory.systemTemp.createTemp('process_group_test_');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  final file = File('${dir.path}/groups');
  final groups = file.openSync(mode: FileMode.writeOnlyAppend)
    ..lockSync(FileLock.exclusive);
  final keeper = await Process.start(await GroupedProcess.helper(), [
    '--keeper',
    file.path,
  ]);
  return (groups: groups, keeper: keeper, file: file);
}

/// Runs `test/helpers/starts_sleep.dart` with [arguments] and reads the
/// program's pid and the id of the group it started.
Future<({Process program, int pid, ProcessGroup group})> startsSleep(
  List<String> arguments,
) async {
  final program = await Process.start(Platform.resolvedExecutable, [
    'test/helpers/starts_sleep.dart',
    ...arguments,
  ]);
  final [pid, group] = utf8
      .decode(await program.stdout.first)
      .trim()
      .split(' ')
      .map(int.parse)
      .toList();
  final started = ProcessGroup(group);
  addTearDown(started.stop);
  return (program: program, pid: pid, group: started);
}

void main() {
  setUpAll(() async {
    try {
      await GroupedProcess.helper();
    } on ProcessGroupHelperMissing {
      final directory = Abi.current().toString().replaceAll('_', '-');
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'zig_hook:build_binaries',
        directory,
      ]);
      if (result.exitCode != 0) {
        fail('Building the helper failed:\n${result.stdout}${result.stderr}');
      }
    }
  });

  test('the command runs with its own pid as the process group', () async {
    final [executable, ...arguments] = shell(r'echo $$', '');
    final process = await GroupedProcess.start(executable, arguments);
    expect((await text(process.stdout)).trim(), '${process.pid}');
    expect(await process.exitCode, 0);
  }, skip: Platform.isWindows ? 'On Windows the pid is the helper\'s.' : null);

  test('with newSession the command leads a session of its own', () async {
    // In the state `ps` prints, a lower case s marks a session leader.
    final [executable, ...arguments] = shell(r'ps -o pgid=,stat= -p $$', '');
    final grouped = await GroupedProcess.start(executable, arguments);
    final [group, state] = (await text(grouped.stdout)).trim().split(spaces);
    expect(group, '${grouped.pid}');
    expect(state, isNot(contains('s')));

    final own = await GroupedProcess.start(
      executable,
      arguments,
      newSession: true,
    );
    final [ownGroup, ownState] = (await text(own.stdout)).trim().split(spaces);
    expect(ownGroup, '${own.pid}');
    expect(ownState, contains('s'));
  }, skip: Platform.isWindows ? 'Windows has no sessions.' : null);

  test('the command runs when Dart starts the helper detached', () async {
    final [executable, ...arguments] = shell(r'echo $$', '');
    final process = await GroupedProcess.start(
      executable,
      arguments,
      mode: ProcessStartMode.detachedWithStdio,
    );
    expect((await text(process.stdout)).trim(), '${process.pid}');
  }, skip: Platform.isWindows ? 'On Windows the pid is the helper\'s.' : null);

  test('kill ends the command and the processes it started', () async {
    final [executable, ...arguments] = shell(
      'sleep 300 & sleep 300 & echo ready; wait',
      r"$p = Start-Process ping -ArgumentList '-n','300','127.0.0.1' "
          r'-PassThru -WindowStyle Hidden; Write-Output $p.Id; '
          r'Wait-Process -Id $p.Id',
    );
    final process = await GroupedProcess.start(executable, arguments);
    final first = utf8.decode(await process.stdout.first).trim();
    if (Platform.isWindows) {
      final child = int.parse(first);
      expect(await windowsProcessExists(child), isTrue);
      expect(process.kill(), isTrue);
      await process.exitCode;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await windowsProcessExists(child), isFalse);
      return;
    }
    expect(await processGroup(process.pid), hasLength(3));
    expect(process.kill(), isTrue);
    expect(await process.exitCode, -ProcessSignal.sigterm.signalNumber);
    // The children die on their own time once signaled.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await processGroup(process.pid), isEmpty);
  });

  test('killCommand leaves what the command started running', () async {
    final process = await GroupedProcess.start('sh', [
      '-c',
      'sleep 300 & echo ready; wait',
    ]);
    await process.stdout.first;
    expect(process.killCommand(ProcessSignal.sigkill), isTrue);
    expect(await process.exitCode, -ProcessSignal.sigkill.signalNumber);
    final group = process.group!;
    expect(await processGroup(group.id), hasLength(1));

    expect(group.kill(ProcessSignal.sigkill), isTrue);
    await emptied(group);
    expect(group.exists, isFalse);
  }, skip: Platform.isWindows ? 'On Windows there is no group.' : null);

  test('ProcessGroup refuses an id whose signal would go elsewhere', () {
    for (final id in [1, 0, -7]) {
      expect(() => ProcessGroup(id), throwsArgumentError, reason: '$id');
    }
  });

  test('the group outlives the command until it is stopped', () async {
    final process = await GroupedProcess.start('sh', [
      '-c',
      'sleep 300 & echo ready',
    ]);
    expect(await process.exitCode, 0);
    final group = process.group!;
    expect(group.id, process.pid);
    expect(group.exists, isTrue);
    expect(await processGroup(group.id), hasLength(1));

    await group.stop();
    expect(group.exists, isFalse);
    expect(group.kill(), isFalse);
  }, skip: Platform.isWindows ? 'On Windows there is no group.' : null);

  test('stop kills what ignores SIGTERM once the grace is over', () async {
    final process = await GroupedProcess.start('sh', [
      '-c',
      'trap "" TERM; sleep 300 & echo ready; wait',
    ]);
    await process.stdout.first;
    final group = process.group!;
    const grace = Duration(milliseconds: 300);
    final waited = Stopwatch()..start();
    await group.stop(grace: grace);
    expect(waited.elapsed, greaterThanOrEqualTo(grace));
    expect(await process.exitCode, -ProcessSignal.sigkill.signalNumber);
    await emptied(group);
    expect(group.exists, isFalse);
  }, skip: Platform.isWindows ? 'On Windows there is no group.' : null);

  test(
    'the keeper stops the groups in its file once the lock is free',
    () async {
      final (:groups, :keeper, :file) = await startKeeper();
      final process = await GroupedProcess.start('sleep', ['300']);
      final group = process.group!;
      groups.writeStringSync('+${group.id}\n');
      // Longer than the keeper takes between two looks at the lock.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(group.exists, isTrue);

      groups.closeSync();
      expect(await keeper.exitCode, 0);
      expect(await process.exitCode, -ProcessSignal.sigterm.signalNumber);
      expect(group.exists, isFalse);
      expect(file.existsSync(), isFalse);
    },
    skip: Platform.isWindows ? 'On Windows there is no group.' : null,
  );

  test('the keeper leaves a group it was told to forget', () async {
    final (:groups, :keeper, file: _) = await startKeeper();
    final process = await GroupedProcess.start('sleep', ['300']);
    final group = process.group!;
    addTearDown(group.stop);
    groups
      ..writeStringSync('+${group.id}\n')
      ..writeStringSync('-${group.id}\n')
      ..closeSync();
    expect(await keeper.exitCode, 0);
    // The helper that leads the group may not have run yet.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(group.exists, isTrue);
  }, skip: Platform.isWindows ? 'On Windows there is no group.' : null);

  test('the keeper stops a group it is told of as the lock is freed', () async {
    final (:groups, :keeper, file: _) = await startKeeper();
    // Nothing waits here for the helper to have made the group, so the
    // keeper may look for it before it exists.
    final process = await GroupedProcess.start('sleep', ['300']);
    groups
      ..writeStringSync('+${process.pid}\n')
      ..closeSync();
    expect(await keeper.exitCode, 0);
    expect(await process.exitCode, -ProcessSignal.sigterm.signalNumber);
  }, skip: Platform.isWindows ? 'On Windows there is no group.' : null);

  test('the keeper ignores a line that names no group of a command', () async {
    final (:groups, :keeper, file: _) = await startKeeper();
    groups
      ..writeStringSync('+1\n+0\n+-7\n+\nstop\n+${'9' * 40}\n')
      ..closeSync();
    // A signal to group 0 would have ended this test, and one to group 1
    // nearly everything else.
    expect(await keeper.exitCode, 0);
  }, skip: Platform.isWindows ? 'On Windows there is no group.' : null);

  test(
    'the keeper kills what ignores SIGTERM once the grace is over',
    () async {
      final (:groups, :keeper, file: _) = await startKeeper();
      final process = await GroupedProcess.start('sh', [
        '-c',
        'trap "" TERM; sleep 300 & echo ready; wait',
      ]);
      await process.stdout.first;
      final group = process.group!;
      groups.writeStringSync('+${group.id}\n');
      final waited = Stopwatch()..start();
      groups.closeSync();
      expect(await keeper.exitCode, 0);
      expect(waited.elapsed, greaterThanOrEqualTo(const Duration(seconds: 2)));
      expect(await process.exitCode, -ProcessSignal.sigkill.signalNumber);
      await emptied(group);
      expect(group.exists, isFalse);
    },
    skip: Platform.isWindows ? 'On Windows there is no group.' : null,
  );

  test('with stopWithParent the group stops when the program is '
      'killed', () async {
    final (program: _, :pid, :group) = await startsSleep(['wait']);
    expect(group.exists, isTrue);

    Process.killPid(pid, ProcessSignal.sigkill);
    await emptied(group);
    expect(group.exists, isFalse);
  }, skip: Platform.isWindows ? 'On Windows there is no group.' : null);

  test('with stopWithParent a program that returns from main still exits, '
      'and the group stops', () async {
    final (:program, pid: _, :group) = await startsSleep([]);
    expect(await program.exitCode.timeout(const Duration(seconds: 20)), 0);
    await emptied(group);
    expect(group.exists, isFalse);
  }, skip: Platform.isWindows ? 'On Windows there is no group.' : null);

  test(
    'the exit code, stdio, environment and directory pass through',
    () async {
      final dir = await Directory.systemTemp.createTemp('process_group_test_');
      addTearDown(() => dir.delete(recursive: true));
      final [executable, ...arguments] = shell(
        r'read line; echo "$line $PROCESS_GROUP_TEST $(pwd)"; echo err >&2; exit 7',
        r'$line = [Console]::In.ReadLine(); '
            r'Write-Output ($line + " " + $env:PROCESS_GROUP_TEST + " " + (Get-Location).Path); '
            r"[Console]::Error.WriteLine('err'); exit 7",
      );
      final process = await GroupedProcess.start(
        executable,
        arguments,
        workingDirectory: dir.path,
        environment: {'PROCESS_GROUP_TEST': 'env'},
      );
      process.stdin.writeln('in');
      await process.stdin.close();
      final expectedDir = Platform.isWindows
          ? dir.path
          : dir.resolveSymbolicLinksSync();
      expect(
        (await text(process.stdout)).trim().toLowerCase(),
        'in env $expectedDir'.toLowerCase(),
      );
      expect((await text(process.stderr)).trim(), 'err');
      expect(await process.exitCode, 7);
    },
  );

  test('the command is found on the PATH of its own environment', () async {
    final dir = await Directory.systemTemp.createTemp('process_group_test_');
    addTearDown(() => dir.delete(recursive: true));
    final tool = File('${dir.path}/process-group-test-tool')
      ..writeAsStringSync('#!/bin/sh\necho found\n');
    await Process.run('chmod', ['+x', tool.path]);
    final process = await GroupedProcess.start(
      'process-group-test-tool',
      [],
      environment: {'PATH': '${dir.path}:${Platform.environment['PATH']}'},
    );
    expect((await text(process.stdout)).trim(), 'found');
    expect(await process.exitCode, 0);
  }, skip: Platform.isWindows ? 'The tool is a shell script.' : null);

  test('a command that does not exist exits with 127', () async {
    final process = await GroupedProcess.start(
      'process-group-no-such-command',
      [],
    );
    expect(await text(process.stderr), contains('process_group_helper:'));
    expect(await process.exitCode, 127);
  });

  test('a path that is not executable exits with 126', () async {
    final dir = await Directory.systemTemp.createTemp('process_group_test_');
    addTearDown(() => dir.delete(recursive: true));
    final plain = File('${dir.path}/plain')..writeAsStringSync('');
    final process = await GroupedProcess.start(plain.path, []);
    expect(await process.exitCode, 126);
  }, skip: Platform.isWindows ? 'Windows has no executable bit.' : null);

  test('helperPath names the helper to start', () async {
    final dir = await Directory.systemTemp.createTemp('process_group_test_');
    addTearDown(() => dir.delete(recursive: true));
    final name = Platform.isWindows ? 'copy.exe' : 'copy';
    final copy = await File(await GroupedProcess.helper())
        .copy('${dir.path}/$name');
    final [executable, ...arguments] = shell('echo out', "Write-Output 'out'");
    final process = await GroupedProcess.start(
      executable,
      arguments,
      helperPath: copy.path,
    );
    expect((await text(process.stdout)).trim(), 'out');
    expect(await process.exitCode, 0);

    final missing = '${dir.path}/missing';
    await expectLater(
      GroupedProcess.start(executable, arguments, helperPath: missing),
      throwsA(
        isA<ProcessException>().having(
          (e) => e.executable,
          'executable',
          missing,
        ),
      ),
    );
  });

  test('the helper is found under binary/ for this platform', () async {
    final helper = await GroupedProcess.helper();
    expect(
      helper,
      endsWith(
        Platform.isWindows
            ? 'process_group_helper.exe'
            : 'process_group_helper',
      ),
    );
    expect(helper, contains(Abi.current().toString().replaceAll('_', '-')));
  });

  group('a compiled program', () {
    late Directory directory;
    late String program;

    /// Runs [executable] without the variable that would name a helper.
    Future<ProcessResult> run(String executable) => Process.run(
      executable,
      [],
      environment: {...Platform.environment}
        ..remove(GroupedProcess.helperVariable),
      includeParentEnvironment: false,
    );

    setUpAll(() async {
      directory = await Directory.systemTemp.createTemp('process_group_test_');
      final name = Platform.isWindows ? 'prints_helper.exe' : 'prints_helper';
      program = directory.uri.resolve(name).toFilePath();
      final compiled = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        'test/helpers/prints_helper.dart',
        '-o',
        program,
      ]);
      if (compiled.exitCode != 0) {
        fail('Compiling failed:\n${compiled.stdout}${compiled.stderr}');
      }
    });

    tearDownAll(() => directory.delete(recursive: true));

    /// Runs `copy_helper` on [target] and returns the copy's path.
    Future<String> copyHelperTo(Directory target) async {
      final copied = await Process.run(Platform.resolvedExecutable, [
        'run',
        'process_group:copy_helper',
        target.path,
      ]);
      expect(copied.exitCode, 0, reason: '${copied.stderr}');
      return (copied.stdout as String).trim();
    }

    test('finds the helper that copy_helper put beside it', () async {
      final copy = await copyHelperTo(directory);
      expect(File(copy).parent.path, directory.path);
      // The helper exits with 64 when it is given no command.
      expect((await Process.run(copy, [])).exitCode, 64);

      final found = await run(program);
      expect(found.exitCode, 0, reason: '${found.stderr}');
      expect(
        FileSystemEntity.identicalSync((found.stdout as String).trim(), copy),
        isTrue,
        reason: '${found.stdout}',
      );
    });

    test(
      'started through a link finds the helper in its own directory',
      () async {
        final copy = await copyHelperTo(directory);
        final elsewhere = await Directory.systemTemp.createTemp(
          'process_group_test_',
        );
        addTearDown(() => elsewhere.delete(recursive: true));
        final link = await Link('${elsewhere.path}/linked').create(program);

        final found = await run(link.path);
        expect(found.exitCode, 0, reason: '${found.stderr}');
        expect(
          FileSystemEntity.identicalSync((found.stdout as String).trim(), copy),
          isTrue,
          reason: '${found.stdout}',
        );
      },
      skip: Platform.isWindows ? 'A link needs a privilege there.' : null,
    );

    test('without a helper beside it says how to get one', () async {
      final bare = await Directory.systemTemp.createTemp('process_group_test_');
      addTearDown(() => bare.delete(recursive: true));
      final copy = await File(program).copy(
        bare.uri.resolve(File(program).uri.pathSegments.last).toFilePath(),
      );

      final found = await run(copy.path);
      expect(found.exitCode, isNot(0));
      expect(found.stderr, contains('process_group:copy_helper'));
    });

    test('copy_helper refuses a directory that does not exist', () async {
      final copied = await Process.run(Platform.resolvedExecutable, [
        'run',
        'process_group:copy_helper',
        '${directory.path}/missing',
      ]);
      expect(copied.exitCode, 1);
      expect(copied.stderr, contains('is no directory'));
    });
  });
}
