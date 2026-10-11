///|
async test "native journal refuses symlinked root journal and temporary paths" {
  let root = @fs.tmpdir(prefix="board-execution-links-")
  defer @fs.rmdir(root, recursive=true)
  @fs.symlink(root + "/linked-root", target=root)
  let linked_root = @native.FileBoardExecutionStore(
    directory=root + "/linked-root",
  )
  assert_true(linked_root.load() is Err(@execution.StoreUnavailable))
  assert_false(@fs.readdir(root).contains("execution.lock"))
  @fs.symlink(root + "/executions.json", target=root + "/absent")
  let linked_journal = @native.FileBoardExecutionStore(directory=root)
  assert_true(linked_journal.load() is Err(@execution.StoreUnavailable))
  linked_journal.close()
  @fs.remove(root + "/executions.json")
  let store = @native.FileBoardExecutionStore(directory=root)
  assert_eq(store.load(), Ok([]))
  @fs.write_file(root + "/target", "unchanged")
  @fs.symlink(root + "/executions.json.tmp", target=root + "/target")
  assert_true(store.persist([]) is Err(@execution.StoreUnavailable))
  assert_eq(@fs.read_file(root + "/target").text(), "unchanged")
  assert_eq(
    @fs.kind(root + "/executions.json.tmp", follow_symlink=false),
    @fs.SymLink,
  )
  store.close()
}
