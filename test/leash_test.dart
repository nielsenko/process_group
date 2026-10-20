import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:leash/leash.dart';
import 'package:test/test.dart';

/// Pids of every process in the group [pgid], from `ps`, which both BSD
/// and procps spell the same way for these flags.
Future<Set<int>> processGroup(int pgid) async {
  final result = await Process.run('ps', ['-A', '-o', 'pid=,pgid=']);
  return {
    for (final line in LineSplitter.split(result.stdout as String))
      if (line.trim().split(RegExp(r'\s+')) case [final pid, final group]
          when int.parse(group) == pgid)
        int.parse(pid),
  };
}

Future<String> text(Stream<List<int>> stream) =>
    stream.transform(utf8.decoder).join();

void main() {
  setUpAll(() async {
    try {
      await Leash.helper();
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
    final process = await Leash.start('sh', ['-c', r'echo $$']);
    expect((await text(process.stdout)).trim(), '${process.pid}');
    expect(await process.exitCode, 0);
  });

  test('kill ends the command and the processes it started', () async {
    final process = await Leash.start('sh', [
      '-c',
      'sleep 300 & sleep 300 & echo ready; wait',
    ]);
    await process.stdout.first;
    expect(await processGroup(process.pid), hasLength(3));

    expect(process.kill(), isTrue);
    expect(await process.exitCode, -ProcessSignal.sigterm.signalNumber);
    // The children die on their own time once signaled.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await processGroup(process.pid), isEmpty);
  });

  test(
    'the exit code, stdio, environment and directory pass through',
    () async {
      final dir = await Directory.systemTemp.createTemp('leash_test_');
      addTearDown(() => dir.delete(recursive: true));
      final process = await Leash.start(
        'sh',
        [
          '-c',
          r'read line; echo "$line $LEASH_TEST $(pwd)"; echo err >&2; exit 7',
        ],
        workingDirectory: dir.path,
        environment: {'LEASH_TEST': 'env'},
      );
      process.stdin.writeln('in');
      await process.stdin.close();
      expect(
        (await text(process.stdout)).trim(),
        'in env ${dir.resolveSymbolicLinksSync()}',
      );
      expect((await text(process.stderr)).trim(), 'err');
      expect(await process.exitCode, 7);
    },
  );

  test('a command that is not on PATH exits with 127', () async {
    final process = await Leash.start('leash-no-such-command', []);
    expect((await text(process.stderr)), contains('command not found'));
    expect(await process.exitCode, 127);
  });

  test('a path that is not executable exits with 126', () async {
    final dir = await Directory.systemTemp.createTemp('leash_test_');
    addTearDown(() => dir.delete(recursive: true));
    final plain = File('${dir.path}/plain')..writeAsStringSync('');
    final process = await Leash.start(plain.path, []);
    expect(await process.exitCode, 126);
  });

  test('the helper is found under binary/ for this platform', () async {
    final helper = await Leash.helper();
    expect(helper, endsWith(Platform.isWindows ? 'leash.exe' : 'leash'));
    expect(helper, contains(Abi.current().toString().replaceAll('_', '-')));
  });
}
