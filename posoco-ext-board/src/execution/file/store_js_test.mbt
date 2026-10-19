///|
fn reserved(
  task~ : String,
  attempt~ : String,
) -> @execution.BoardExecutionBinding {
  {
    task_id: task,
    attempt_id: attempt,
    execution_id: "exec-" + attempt,
    session_id: "session-" + task,
    run: None,
    phase: @execution.Reserved,
    outcome: None,
  }
}

///|
/// Node file content; None also covers rejected symlink paths (never followed).
fn written(path : String) -> String? {
  match @node_fs.read(path) {
    Ok(Some(text)) => Some(text)
    _ => None
  }
}

///|
fn journalled(
  path : String,
) -> Result[
  Array[@execution.BoardExecutionBinding],
  @execution.BoardExecutionError,
] {
  match written(path) {
    Some(text) => @execution.decode_execution_journal(text)
    None => Err(@execution.StoreUnavailable)
  }
}

///|
async test "JS journal admits exactly one lock owner and reloads identity after confirmed close" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  let owner = @file.FileBoardExecutionStore(directory~)
  assert_eq(owner.load(), Ok([]))
  let competitor = @file.FileBoardExecutionStore(directory~)
  assert_true(competitor.load() is Err(@execution.StoreUnavailable))
  assert_true(competitor.persist([]) is Err(@execution.StoreUnavailable))
  // Closing without ever owning the lock leaves the live owner untouched.
  competitor.close()
  let lock = @node_fs.read(directory + "/execution.lock")
  assert_true(
    lock is Ok(Some(token)) && token.has_prefix("board-execution-journal-v1:"),
  )
  assert_true(
    owner.persist([reserved(task="task-a", attempt="attempt-a")]) is Ok(_),
  )
  assert_eq(
    journalled(directory + "/executions.json"),
    Ok([reserved(task="task-a", attempt="attempt-a")]),
  )
  owner.close()
  owner.close()
  assert_eq(written(directory + "/execution.lock"), None)
  let restarted = @file.FileBoardExecutionStore(directory~)
  assert_eq(
    restarted.load(),
    Ok([reserved(task="task-a", attempt="attempt-a")]),
  )
  restarted.close()
}

///|
async test "JS inspect reads recovery evidence without acquiring or stealing the execution lock" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  assert_eq(@file.FileBoardExecutionStore::inspect(directory~), Ok([]))
  assert_eq(written(directory + "/execution.lock"), None)
  let owner = @file.FileBoardExecutionStore(directory~)
  assert_eq(owner.load(), Ok([]))
  assert_true(
    owner.persist([reserved(task="task-b", attempt="attempt-b")]) is Ok(_),
  )
  let lock_before = @node_fs.read(directory + "/execution.lock")
  assert_eq(
    @file.FileBoardExecutionStore::inspect(directory~),
    Ok([reserved(task="task-b", attempt="attempt-b")]),
  )
  assert_eq(@node_fs.read(directory + "/execution.lock"), lock_before)
  assert_true(
    owner.persist([reserved(task="task-b", attempt="attempt-b")]) is Ok(_),
  )
  owner.close()
  assert_eq(written(directory + "/execution.lock"), None)
  assert_eq(
    @file.FileBoardExecutionStore::inspect(directory~),
    Ok([reserved(task="task-b", attempt="attempt-b")]),
  )
  assert_eq(written(directory + "/execution.lock"), None)
}

///|
async test "JS stale execution lock fails closed and is never removed or reacquired" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @fixtures.put(directory + "/execution.lock", "old owner unknown")
  let store = @file.FileBoardExecutionStore(directory~)
  assert_true(store.load() is Err(@execution.StoreUnavailable))
  assert_true(store.persist([]) is Err(@execution.StoreUnavailable))
  store.close()
  assert_eq(
    @node_fs.read(directory + "/execution.lock"),
    Ok(Some("old owner unknown")),
  )
  assert_eq(written(directory + "/executions.json"), None)
  let successor = @file.FileBoardExecutionStore(directory~)
  assert_true(successor.load() is Err(@execution.StoreUnavailable))
  successor.close()
  assert_eq(
    @node_fs.read(directory + "/execution.lock"),
    Ok(Some("old owner unknown")),
  )
}

///|
async test "JS journal rename failures poison the owner without replay and keep renamed identities complete" {
  let complete = [
    reserved(task="task-c", attempt="attempt-c"),
    reserved(task="task-d", attempt="attempt-d"),
  ]
  for stage in [@file.BeforeRename, @file.AfterRename] {
    let directory = @fixtures.temporary_directory()
    defer @fixtures.cleanup(directory)
    let writer = @file.FileBoardExecutionStore(directory~)
    assert_eq(writer.load(), Ok([]))
    assert_true(writer.persist(complete) is Ok(_))
    writer.close()
    let extra = [
      reserved(task="task-e", attempt="attempt-e"),
      reserved(task="task-f", attempt="attempt-f"),
    ]
    let failing = @file.FileBoardExecutionStore(directory~, fail_at=stage)
    assert_eq(failing.load(), Ok(complete))
    assert_true(failing.persist(extra) is Err(@execution.StoreUnavailable))
    assert_true(failing.load() is Err(@execution.StoreUnavailable))
    assert_true(failing.persist([]) is Err(@execution.StoreUnavailable))
    failing.close()
    // No stale temporary is left behind and the journal only ever shows one
    // complete atomic write, never a partial or replayed identity set.
    assert_eq(written(directory + "/executions.json.tmp"), None)
    let expected = if stage == @file.AfterRename { extra } else { complete }
    assert_eq(journalled(directory + "/executions.json"), Ok(expected))
    let restarted = @file.FileBoardExecutionStore(directory~)
    assert_eq(restarted.load(), Ok(expected))
    restarted.close()
  }
}

///|
async test "JS journal rejects symlinked evidence and temporary paths without following them" {
  // A symlinked journal is never followed on load, even when the target exists.
  let linked = @fixtures.temporary_directory()
  defer @fixtures.cleanup(linked)
  @fixtures.put(linked + "/evidence", "evidence untouched")
  @fixtures.link(linked + "/evidence", linked + "/executions.json")
  let reader = @file.FileBoardExecutionStore(directory=linked)
  assert_true(reader.load() is Err(@execution.StoreUnavailable))
  assert_true(reader.persist([]) is Err(@execution.StoreUnavailable))
  reader.close()
  assert_eq(@node_fs.read(linked + "/evidence"), Ok(Some("evidence untouched")))
  // A symlinked temporary is never overwritten, replaced or promoted.
  let staged = @fixtures.temporary_directory()
  defer @fixtures.cleanup(staged)
  let owner = @file.FileBoardExecutionStore(directory=staged)
  assert_eq(owner.load(), Ok([]))
  @fixtures.put(staged + "/target", "unchanged")
  @fixtures.link(staged + "/target", staged + "/executions.json.tmp")
  assert_true(
    owner.persist([reserved(task="task-f", attempt="attempt-f")])
    is Err(@execution.StoreUnavailable),
  )
  assert_true(owner.persist([]) is Err(@execution.StoreUnavailable))
  owner.close()
  assert_eq(@node_fs.read(staged + "/target"), Ok(Some("unchanged")))
  assert_eq(written(staged + "/executions.json"), None)
  let restarted = @file.FileBoardExecutionStore(directory=staged)
  assert_eq(restarted.load(), Ok([]))
  restarted.close()
}
