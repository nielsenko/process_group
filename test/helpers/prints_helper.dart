import 'dart:io';

import 'package:process_group/process_group.dart';

/// Prints the path of the helper this program finds.
Future<void> main() async {
  stdout.writeln(await GroupedProcess.helper());
}
