// Copies the helper executable for this platform into a directory, for a
// compiled program to take along:
//
//   dart build cli
//   dart run process_group:copy_helper build/cli/macos_arm64/bundle/bin
//
// GroupedProcess.helper looks in the directory of the running program
// before it looks in this package, which a compiled program cannot count
// on resolving.
import 'dart:io';

import 'package:process_group/process_group.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 || arguments.single.startsWith('-')) {
    stderr.writeln('Usage: dart run process_group:copy_helper <directory>');
    exit(64);
  }
  final directory = Directory(arguments.single);
  if (!directory.existsSync()) {
    stderr.writeln('${directory.path} is no directory.');
    exit(1);
  }
  final File helper;
  try {
    helper = File(await GroupedProcess.packagedHelper());
  } on ProcessGroupHelperMissing catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  final copy = File.fromUri(
    directory.uri.resolve(helper.uri.pathSegments.last),
  );
  if (copy.existsSync()) {
    if (FileSystemEntity.identicalSync(helper.path, copy.path)) return;
    // A keeper started from the earlier copy may still run. Deleted, that
    // file stays as it is for the keeper, and the new one gets the mode of
    // the helper it is copied from.
    copy.deleteSync();
  }
  helper.copySync(copy.path);
  stdout.writeln(copy.path);
}
