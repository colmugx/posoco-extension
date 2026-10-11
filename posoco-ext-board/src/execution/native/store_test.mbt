///|
fn reserved() -> @execution.BoardExecutionBinding {
  {
    task_id: "task",
    attempt_id: "attempt",
    execution_id: "exec",
    session_id: "session",
    run: None,
    phase: @execution.Reserved,
    outcome: None,
  }
}

///|
async test "native journal persists identities separately from S3 Board state and locks competing owners" {
  let root = @fs.tmpdir(prefix="board-execution-")
  defer @fs.rmdir(root, recursive=true)
  let first = @native.FileBoardExecutionStore(directory=root)
  assert_eq(first.load(), Ok([]))
  let competitor = @native.FileBoardExecutionStore(directory=root)
  assert_true(competitor.load() is Err(@execution.StoreUnavailable))
  competitor.close()
  assert_true(@fs.readdir(root).contains("execution.lock"))
  assert_true(first.persist([reserved()]) is Ok(_))
  let encoded = @fs.read_file(root + "/executions.json").text()
  assert_eq(@execution.decode_execution_journal(encoded), Ok([reserved()]))
  assert_false(encoded.contains("input"))
  first.close()
  first.close()
  let restarted = @native.FileBoardExecutionStore(directory=root)
  assert_eq(restarted.load(), Ok([reserved()]))
  restarted.close()
}

///|
async test "native pre and post rename journal failures forbid subsequent writes" {
  for stage in [@native.BeforeRename, @native.AfterRename] {
    let root = @fs.tmpdir(prefix="board-execution-failure-")
    defer @fs.rmdir(root, recursive=true)
    let store = @native.FileBoardExecutionStore(directory=root, fail_at=stage)
    assert_eq(store.load(), Ok([]))
    assert_true(store.persist([reserved()]) is Err(@execution.StoreUnavailable))
    assert_true(store.persist([]) is Err(@execution.StoreUnavailable))
    let names = @fs.readdir(root)
    assert_eq(names.contains("executions.json"), stage == @native.AfterRename)
    assert_false(names.contains("executions.json.tmp"))
    store.close()
    let restarted = @native.FileBoardExecutionStore(directory=root)
    assert_eq(
      restarted.load(),
      Ok(if stage == @native.AfterRename { [reserved()] } else { [] }),
    )
    restarted.close()
  }
}

///|
async test "native journal rejects corrupt files and existing temp paths without overwriting" {
  let root = @fs.tmpdir(prefix="board-execution-unsafe-")
  defer @fs.rmdir(root, recursive=true)
  @fs.write_file(
    root + "/executions.json",
    "{\"schema_version\":2,\"bindings\":[]}",
  )
  let corrupt = @native.FileBoardExecutionStore(directory=root)
  assert_true(corrupt.load() is Err(@execution.StoreUnavailable))
  assert_true(corrupt.persist([]) is Err(@execution.StoreUnavailable))
  corrupt.close()
  @fs.remove(root + "/executions.json")
  let blocked = @native.FileBoardExecutionStore(directory=root)
  assert_eq(blocked.load(), Ok([]))
  @fs.write_file(root + "/executions.json.tmp", "do not overwrite")
  assert_true(blocked.persist([reserved()]) is Err(@execution.StoreUnavailable))
  assert_eq(
    @fs.read_file(root + "/executions.json.tmp").text(),
    "do not overwrite",
  )
  blocked.close()
}

///|
async test "stale lock after crash is never removed or automatically reacquired" {
  let root = @fs.tmpdir(prefix="board-execution-stale-")
  defer @fs.rmdir(root, recursive=true)
  @fs.write_file(root + "/execution.lock", "old owner unknown")
  let store = @native.FileBoardExecutionStore(directory=root)
  assert_true(store.load() is Err(@execution.StoreUnavailable))
  store.close()
  assert_eq(@fs.read_file(root + "/execution.lock").text(), "old owner unknown")
}
