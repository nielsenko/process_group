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
Future<void> emptied(LeashGroup group) async {
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

void main() {
  setUpAll(() async {
    try {
      await LeashedProcess.helper();
    } on LeashHelperMissing {
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
    final process = await LeashedProcess.start(executable, arguments);
    expect((await text(process.stdout)).trim(), '${process.pid}');
    expect(await process.exitCode, 0);
  }, skip: Platform.isWindows ? 'On Windows the pid is the helper\'s.' : null);

  test('with newSession the command leads a session of its own', () async {
    // In the state `ps` prints, a lower case s marks a session leader.
    final [executable, ...arguments] = shell(r'ps -o pgid=,stat= -p $$', '');
    final grouped = await LeashedProcess.start(executable, arguments);
    final [group, state] = (await text(grouped.stdout)).trim().split(spaces);
    expect(group, '${grouped.pid}');
    expect(state, isNot(contains('s')));

    final own = await LeashedProcess.start(
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
    final process = await LeashedProcess.start(
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
    final process = await LeashedProcess.start(executable, arguments);
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
    final process = await LeashedProcess.start('sh', [
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

  test('LeashGroup refuses an id whose signal would go elsewhere', () {
    for (final id in [1, 0, -7]) {
      expect(() => LeashGroup(id), throwsArgumentError, reason: '$id');
    }
  });

  test('the group outlives the command until it is stopped', () async {
    final process = await LeashedProcess.start('sh', [
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
    final process = await LeashedProcess.start('sh', [
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
      final process = await LeashedProcess.start(
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
    final process = await LeashedProcess.start(
      'process-group-test-tool',
      [],
      environment: {'PATH': '${dir.path}:${Platform.environment['PATH']}'},
    );
    expect((await text(process.stdout)).trim(), 'found');
    expect(await process.exitCode, 0);
  }, skip: Platform.isWindows ? 'The tool is a shell script.' : null);

  test('a command that does not exist exits with 127', () async {
    final process = await LeashedProcess.start(
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
    final process = await LeashedProcess.start(plain.path, []);
    expect(await process.exitCode, 126);
  }, skip: Platform.isWindows ? 'Windows has no executable bit.' : null);

  test('helperPath names the helper to start', () async {
    final dir = await Directory.systemTemp.createTemp('process_group_test_');
    addTearDown(() => dir.delete(recursive: true));
    final name = Platform.isWindows ? 'copy.exe' : 'copy';
    final copy = await File(await LeashedProcess.helper())
        .copy('${dir.path}/$name');
    final [executable, ...arguments] = shell('echo out', "Write-Output 'out'");
    final process = await LeashedProcess.start(
      executable,
      arguments,
      helperPath: copy.path,
    );
    expect((await text(process.stdout)).trim(), 'out');
    expect(await process.exitCode, 0);

    final missing = '${dir.path}/missing';
    await expectLater(
      LeashedProcess.start(executable, arguments, helperPath: missing),
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
    final helper = await LeashedProcess.helper();
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
}
