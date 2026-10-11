///|
struct ScriptedJournal {
  mut records : Array[@execution.BoardExecutionBinding]
  mut writes : Int
  fail_write : Int
  visible_failure : Bool
}

///|
impl @execution.BoardExecutionStore for ScriptedJournal with fn load(self) {
  Ok(self.records.copy())
}

///|
impl @execution.BoardExecutionStore for ScriptedJournal with fn persist(
  self,
  records,
) {
  self.writes += 1
  if self.writes == self.fail_write {
    if self.visible_failure {
      self.records = records.copy()
    }
    return Err(@execution.StoreUnavailable)
  }
  self.records = records.copy()
  Ok(())
}

///|
fn journal(
  fail_write? : Int = -1,
  visible_failure? : Bool = false,
) -> ScriptedJournal {
  { records: [], writes: 0, fail_write, visible_failure, }
}

///|
struct ControlledAdapter {
  mut calls : Int
  mut effects : Int
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
  block : Bool
  wrong_scope : Bool
  repeat_gate : Bool
  available : Bool
  outcome : @execution.BoardExecutionOutcome
}

///|
fn controlled(
  block? : Bool = false,
  wrong_scope? : Bool = false,
  repeat_gate? : Bool = false,
  available? : Bool = true,
  outcome? : @execution.BoardExecutionOutcome = @execution.Completed,
) -> ControlledAdapter {
  {
    calls: 0,
    effects: 0,
    entered: @aqueue.Queue(kind=Unbounded),
    release: @aqueue.Queue(kind=Unbounded),
    block,
    wrong_scope,
    repeat_gate,
    available,
    outcome,
  }
}

///|
impl @execution.BoardExecutionAdapter for ControlledAdapter with fn ready(self) {
  self.available
}

///|
impl @execution.BoardExecutionAdapter for ControlledAdapter with fn run(
  self,
  request,
  start,
) {
  self.calls += 1
  let scope : @execution.BoardExecutionRun = {
    session_id: if self.wrong_scope {
      "foreign"
    } else {
      request.session_id
    },
    run_id: "run",
    turn_id: "turn",
  }
  if !start(scope) {
    return @execution.Failed
  }
  if self.repeat_gate {
    assert_false(start(scope))
  }
  self.effects += 1
  self.entered.put(())
  if self.block {
    self.release.get()
  }
  self.outcome
}

///|
async test "admission validates live queued Execute state and rejects host unavailable without effects" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let adapter = controlled()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal(),
    )
    assert_true(owner.execute(request()) is Err(@execution.NotReady))
    assert_true(owner.attach(group) is Ok(_))
    for
      invalid in [
        { ..request(), task_id: "missing", },
        { ..request(), attempt_id: "missing", },
      ] {
      assert_true(owner.execute(invalid) is Err(@execution.IneligibleAttempt))
    }
    for
      invalid in [
        { ..request(), input: " ", },
        { ..request(), timeout_ms: Some(0), },
        { ..request(), execution_id: "", },
        { ..request(), session_id: " ", },
      ] {
      assert_true(owner.execute(invalid) is Err(@execution.InvalidRequest))
    }
    for kind in ["discuss", "review"] {
      let state = backend.state().unwrap()
      assert_true(
        backend.handle_command({
          command_id: kind,
          name: "board.attempt.queue",
          expected_revision: state.revision,
          args: { "id": kind, "task_id": "task", "kind": kind },
        }).accepted,
      )
      assert_true(
        owner.execute({ ..request(), attempt_id: kind, })
        is Err(@execution.IneligibleAttempt),
      )
    }
    let revision = backend.state().unwrap().revision
    assert_true(
      backend.handle_command({
        command_id: "manual",
        name: "board.attempt.start",
        expected_revision: revision,
        args: { "id": "attempt" },
      }).accepted,
    )
    assert_true(owner.execute(request()) is Err(@execution.IneligibleAttempt))
    assert_eq(adapter.calls, 0)
    assert_true(owner.shutdown())
    assert_true(owner.execute(request()) is Err(@execution.Closed))
    let unavailable = @execution.BoardExecutionOwner(
      backend~,
      adapter=controlled(available=false),
      store=journal(),
    )
    assert_true(unavailable.attach(group) is Ok(_))
    assert_true(unavailable.execute(request()) is Err(@execution.NotReady))
    assert_true(unavailable.shutdown())
    backend.shutdown()
  })
}

///|
async test "one active execution owner rejects concurrent admission and duplicate gate settlement" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let adapter = controlled(block=true, repeat_gate=true)
    let store = journal()
    let owner = @execution.BoardExecutionOwner(backend~, adapter~, store~)
    assert_true(owner.attach(group) is Ok(_))
    let contenders = [
      group.spawn(() => owner.execute(request())),
      group.spawn(() => owner.execute(request())),
    ]
    let first = contenders[0].wait()
    let second = contenders[1].wait()
    let handle = match (first, second) {
      (Ok(handle), Err(@execution.Busy)) | (Err(@execution.Busy), Ok(handle)) =>
        handle
      _ => fail("exactly one admission must own execution")
    }
    adapter.entered.get()
    assert_eq(store.records[0].phase, @execution.Running)
    assert_true(store.records[0].run is Some(_))
    assert_eq(backend.state().unwrap().attempts[0].status, @domain.Running)
    adapter.release.put(())
    let finished = handle.wait()
    assert_eq(handle.wait(), finished)
    assert_eq(finished.phase, @execution.Settled)
    assert_eq(adapter.effects, 1)
    assert_eq(store.writes, 5)
    assert_true(owner.execute(request()) is Err(@execution.DuplicateIdentity))
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "journal failures at every admission and settlement boundary never retry ambiguous writes" {
  for visible in [false, true] {
    for step in 1..<=5 {
      @async.with_task_group(group => {
        let backend = prepared_board(group)
        let adapter = controlled()
        let store = journal(fail_write=step, visible_failure=visible)
        let owner = @execution.BoardExecutionOwner(backend~, adapter~, store~)
        assert_true(owner.attach(group) is Ok(_))
        match owner.execute(request()) {
          Err(@execution.StoreUnavailable) => assert_eq(step, 1)
          Ok(handle) => assert_eq(handle.wait().phase, @execution.Unresolved)
          _ => fail("unexpected admission")
        }
        assert_eq(store.writes, step)
        assert_eq(adapter.effects, if step <= 3 { 0 } else { 1 })
        assert_eq(
          backend.state().unwrap().revision,
          if step <= 2 {
            2L
          } else if step <= 4 {
            3L
          } else {
            4L
          },
        )
        assert_true(
          owner.execute({ ..request(), execution_id: "another", })
          is Err(@execution.NotReady),
        )
        assert_true(owner.shutdown())
        backend.shutdown()
      })
    }
  }
}

///|
async test "wrong actual scope cannot start Board or model effects and records unresolved identity" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let adapter = controlled(wrong_scope=true)
    let store = journal()
    let owner = @execution.BoardExecutionOwner(backend~, adapter~, store~)
    assert_true(owner.attach(group) is Ok(_))
    let handle = owner.execute(request()).unwrap()
    assert_eq(handle.wait().phase, @execution.Unresolved)
    assert_eq(store.records[0].phase, @execution.Unresolved)
    assert_eq(adapter.effects, 0)
    assert_eq(backend.state().unwrap().revision, 2L)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "manual finish race is never overwritten by owned completion" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let adapter = controlled(block=true)
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let handle = owner.execute(request()).unwrap()
    adapter.entered.get()
    assert_true(
      backend.handle_command({
        command_id: "manual-finish",
        name: "board.attempt.finish",
        expected_revision: 3L,
        args: { "id": "attempt", "outcome": "failed" },
      }).accepted,
    )
    adapter.release.put(())
    assert_eq(handle.wait().phase, @execution.Unresolved)
    assert_eq(backend.state().unwrap().attempts[0].status, @domain.Failed)
    assert_eq(
      backend
      .event_history()
      .filter(e => e.kind == "board.attempt.finished")
      .length(),
      1,
    )
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "restart never replays reserved running completed or unresolved execution" {
  for
    phase in [
      @execution.Reserved,
      @execution.Running,
      @execution.Finished,
      @execution.Unresolved,
      @execution.Settled,
    ] {
    @async.with_task_group(group => {
      let backend = prepared_board(group)
      let store = journal()
      let run : @execution.BoardExecutionRun? = if phase == @execution.Reserved {
        None
      } else {
        Some({ session_id: "session-exec", run_id: "run", turn_id: "turn", })
      }
      let outcome = if phase == @execution.Finished ||
        phase == @execution.Settled {
        Some(@execution.Completed)
      } else {
        None
      }
      let binding : @execution.BoardExecutionBinding = {
        task_id: "task",
        attempt_id: "attempt",
        execution_id: "exec",
        session_id: "session-exec",
        run,
        phase,
        outcome,
      }
      store.records.push(binding)
      let adapter = controlled()
      let owner = @execution.BoardExecutionOwner(backend~, adapter~, store~)
      assert_true(owner.attach(group) is Ok(_))
      if phase == @execution.Settled {
        assert_true(
          owner.execute(request()) is Err(@execution.DuplicateIdentity),
        )
      } else {
        assert_true(owner.execute(request()) is Err(@execution.NotReady))
      }
      assert_eq(adapter.calls, 0)
      let detached = owner.bindings()
      detached.clear()
      assert_eq(owner.bindings(), [binding])
      assert_true(owner.shutdown())
      backend.shutdown()
    })
  }
}

///|
struct FailingBoardStorage {
  inner : @store.MemoryBoardStore
  mut fail : Bool
  uncertain : Bool
  mut failures : Int
}

///|
impl @store.BoardStore for FailingBoardStorage with fn load(self) {
  self.inner.load()
}

///|
impl @store.BoardStore for FailingBoardStorage with fn persist(
  self,
  snapshot,
  events,
) {
  if self.fail {
    self.failures += 1
    if self.uncertain {
      ignore(self.inner.persist(snapshot, events))
      return Err(@store.DurabilityUncertain("injected"))
    }
    return Err(@store.Io("injected"))
  }
  self.inner.persist(snapshot, events)
}

///|
async test "durable finish failure or uncertainty never retries and keeps authoritative reconciliation" {
  for uncertain in [false, true] {
    @async.with_task_group(group => {
      let storage = FailingBoardStorage::{
        inner: @store.MemoryBoardStore(),
        fail: false,
        uncertain,
        failures: 0,
      }
      let backend = prepared_board(group, store=storage)
      let adapter = controlled(block=true)
      let owner = @execution.BoardExecutionOwner(
        backend~,
        adapter~,
        store=journal(),
      )
      assert_true(owner.attach(group) is Ok(_))
      let handle = owner.execute(request()).unwrap()
      adapter.entered.get()
      storage.fail = true
      adapter.release.put(())
      assert_eq(handle.wait().phase, @execution.Unresolved)
      assert_eq(storage.failures, 1)
      let state = backend.state().unwrap()
      assert_eq(state.revision, if uncertain { 4L } else { 3L })
      assert_eq(
        state.attempts[0].status,
        if uncertain {
          @domain.Succeeded
        } else {
          @domain.Running
        },
      )
      assert_eq(
        backend
        .event_history()
        .filter(e => e.kind == "board.attempt.finished")
        .length(),
        if uncertain {
          1
        } else {
          0
        },
      )
      assert_true(owner.shutdown())
      backend.shutdown()
    })
  }
}

///|
async test "final shutdown confirms scoped cancellation before settlement and stops admission" {
  @async.with_task_group(group => {
    let backend = prepared_board(group)
    let adapter = controlled(block=true)
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let handle = owner.execute(request()).unwrap()
    adapter.entered.get()
    assert_true(owner.shutdown(timeout_ms=1000))
    assert_eq(handle.wait().outcome, Some(@execution.Cancelled))
    assert_eq(backend.state().unwrap().attempts[0].status, @domain.Cancelled)
    assert_true(owner.execute(request()) is Err(@execution.Closed))
    backend.shutdown()
  })
}
