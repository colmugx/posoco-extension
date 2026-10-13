///|
/// Slot driver that refuses effects until its own identity is durably Running
/// in the native journal, then holds the slot until released.
struct JournalSlotProbe {
  journal : @native.FileBoardExecutionStore
  mut calls : Int32
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
}

///|
impl @execution.BoardExecutionAdapter for JournalSlotProbe with fn ready(_self) {
  true
}

///|
impl @execution.BoardExecutionAdapter for JournalSlotProbe with fn run(
  self,
  request,
  start,
) {
  self.calls += 1
  let scope : @execution.BoardExecutionRun = {
    session_id: request.session_id,
    run_id: "run",
    turn_id: "turn",
  }
  if !start(scope) {
    return @execution.Failed
  }
  let recorded = @execution.BoardExecutionStore::load(self.journal) catch {
    _ => return @execution.Failed
  }
  guard recorded is Ok(records) &&
    records.any(record => {
      record.execution_id == request.execution_id &&
      record.phase == @execution.Running &&
      record.run is Some(run) &&
      run.session_id == scope.session_id
    }) else {
    return @execution.Failed
  }
  self.entered.put(())
  self.release.get()
  @execution.Completed
}

///|
fn journal_slots(
  journal~ : @native.FileBoardExecutionStore,
  count~ : Int32,
) -> (Array[JournalSlotProbe], (Int32) -> &@execution.BoardExecutionAdapter) {
  let probes : Array[JournalSlotProbe] = []
  for _ in 0..<count {
    probes.push({
      journal,
      calls: 0,
      entered: @aqueue.Queue(kind=Unbounded),
      release: @aqueue.Queue(kind=Unbounded),
    })
  }
  (probes, slot => probes[slot])
}

///|
fn journal_request(
  task : String,
  attempt : String,
  execution : String,
) -> @execution.BoardExecutionRequest {
  {
    task_id: task,
    attempt_id: attempt,
    execution_id: execution,
    session_id: "session-" + execution,
    input: "explicit input",
    timeout_ms: None,
  }
}

///|
async test "native journal serializes multi-slot identities with v1 records lock and restart semantics" {
  let root = @fs.tmpdir(prefix="board-execution-multi-slot-")
  defer @fs.rmdir(root, recursive=true)
  let journal = @native.FileBoardExecutionStore(directory=root)
  @async.with_task_group(group => {
    let backend = @backend.BoardBackend(store=@store.FileBoardStore(root~), now_ms=() => {
      100L
    })
    backend.attach(group)
    assert_true(backend.bootstrap_snapshot() is Ok(_))
    assert_true(
      backend.handle_command({
        command_id: "create-1",
        name: "board.task.create",
        expected_revision: 0L,
        args: {
          "id": "task-1",
          "title": "t",
          "description": "",
          "priority": "normal",
          "definition_of_done": [],
          "dependencies": [],
        },
      }).accepted,
    )
    assert_true(
      backend.handle_command({
        command_id: "create-2",
        name: "board.task.create",
        expected_revision: 1L,
        args: {
          "id": "task-2",
          "title": "t",
          "description": "",
          "priority": "normal",
          "definition_of_done": [],
          "dependencies": [],
        },
      }).accepted,
    )
    assert_true(
      backend.handle_command({
        command_id: "queue-1",
        name: "board.attempt.queue",
        expected_revision: 2L,
        args: { "id": "attempt-1", "task_id": "task-1", "kind": "execute" },
      }).accepted,
    )
    assert_true(
      backend.handle_command({
        command_id: "queue-2",
        name: "board.attempt.queue",
        expected_revision: 3L,
        args: { "id": "attempt-2", "task_id": "task-2", "kind": "execute" },
      }).accepted,
    )
    let (probes, factory) = journal_slots(journal~, count=2)
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store=journal,
      adapter_factory=factory,
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    let first = owner
      .execute(journal_request("task-1", "attempt-1", "exec-1"))
      .unwrap()
    let second = owner
      .execute(journal_request("task-2", "attempt-2", "exec-2"))
      .unwrap()
    probes[0].entered.get()
    probes[1].entered.get()
    // Both slots hold durable Running identities in one v1 journal file.
    let records = @execution.BoardExecutionStore::load(journal).unwrap()
    assert_eq(records.length(), 2)
    for record in records {
      assert_eq(record.phase, @execution.Running)
      assert_true(record.run is Some(_))
    }
    // The native lock still excludes competing journal owners.
    let competitor = @native.FileBoardExecutionStore(directory=root)
    assert_true(competitor.load() is Err(@execution.StoreUnavailable))
    competitor.close()
    probes[0].release.put(())
    probes[1].release.put(())
    assert_eq(first.wait().phase, @execution.Settled)
    assert_eq(second.wait().phase, @execution.Settled)
    assert_eq(probes[0].calls, 1)
    assert_eq(probes[1].calls, 1)
    assert_true(owner.shutdown())
    backend.shutdown()
    journal.close()
  })
  let encoded = @fs.read_file(root + "/executions.json").text()
  assert_false(encoded.contains("input"))
  assert_true(encoded.contains("\"schema_version\":1"))
  let decoded = @execution.decode_execution_journal(encoded).unwrap()
  assert_eq(decoded.length(), 2)
  for record in decoded {
    assert_eq(record.phase, @execution.Settled)
    assert_eq(record.outcome, Some(@execution.Completed))
  }
  // Restart: settled identities stay globally unique across slots and no
  // execution is replayed from the recovered journal.
  let restarted = @native.FileBoardExecutionStore(directory=root)
  @async.with_task_group(group => {
    let backend = @backend.BoardBackend(store=@store.FileBoardStore(root~))
    backend.attach(group)
    assert_true(backend.bootstrap_snapshot() is Ok(_))
    let (probes, factory) = journal_slots(journal=restarted, count=2)
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store=restarted,
      adapter_factory=factory,
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    assert_false(owner.status().unresolved)
    assert_true(
      owner.execute(journal_request("task-1", "attempt-1", "exec-1"))
      is Err(@execution.DuplicateIdentity),
    )
    assert_eq(probes[0].calls, 0)
    assert_eq(probes[1].calls, 0)
    assert_true(owner.shutdown())
    backend.shutdown()
    restarted.close()
  })
}
