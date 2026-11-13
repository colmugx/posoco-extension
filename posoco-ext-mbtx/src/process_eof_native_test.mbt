///|
/// A native child must deliver EOF on stdout and stderr after exit.
/// Regression for the Shared pipe write-end leak in with_process: waiting
/// for a successful child and draining both readers used to wait forever.
async test "native process closes stdout and stderr after child exit" {
  let (code, output) = @async.with_timeout(15000, () => {
    collect_process("moon", ["--version"], None)
  })
  assert_eq(code, 0)
  assert_true(output.contains("moon"))
}

///|
/// Exercise the same EOF path when the child emits a nonzero exit status.
/// The process exit is ordinary result data; the readers still have to close.
async test "native process stderr drain finishes after failed command" {
  let (code, output) = @async.with_timeout(15000, () => {
    collect_process("moon", ["--definitely-invalid-option"], None)
  })
  assert_true(code != 0)
  assert_true(output.length() > 0)
}
