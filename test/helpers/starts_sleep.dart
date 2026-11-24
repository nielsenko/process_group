import 'dart:io';

import 'package:process_group/process_group.dart';

/// Starts `sleep` in a group that is to stop with this program, and prints
/// this program's pid and the group's id.
///
/// With `wait` it then waits to be killed. Without, it returns, and the
/// `sleep` is started detached so that Dart does not wait for it.
Future<void> main(List<String> arguments) async {
  final wait = arguments.contains('wait');
  final process = await GroupedProcess.start(
    'sleep',
    ['300'],
    mode: wait ? ProcessStartMode.normal : ProcessStartMode.detached,
    stopWithParent: true,
  );
  stdout.writeln('$pid ${process.pid}');
  if (wait) await Future<void>.delayed(const Duration(minutes: 5));
}
