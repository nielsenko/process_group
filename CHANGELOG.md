## 0.1.0

- Initial version.
- `GroupedProcess.start` takes `stopWithParent`, which has a keeper process
  stop the command's process group once the program is gone.
- `GroupedProcess.helper` looks in the directory of the running program
  before the package. `dart run process_group:copy_helper <directory>`
  puts the helper there for a compiled program.
- `GroupedProcess.packagedHelper` is the helper under the package's
  `binary/`.
