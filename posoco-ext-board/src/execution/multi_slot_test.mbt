///|
/// Journal that holds one chosen write in flight so tests can observe that no
/// other slot's protected section interleaves with it.
struct HeldJournal {
  inner : @execution.MemoryBoardExecutionStore
  mut writes : Int32
  block_write : Int32
  signal_write : Int32
  mut writing : Bool
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
  signaled : @aqueue.Queue[Unit]
}

///|
impl @execution.BoardExecutionStore for HeldJournal with fn load(self) {
  self.inner.load()
}

///|
impl @execution.BoardExecutionStore for HeldJournal with fn persist(
  self,
  records,
) {
  assert_false(self.writing)
  self.writing = true
  self.writes += 1
  if self.writes == self.block_write {
    self.entered.put(())
    self.release.get()
  }
  if self.writes == self.signal_write {
    ignore(self.signaled.try_put(()) catch { _ => false })
  }
  self.writing = false
  let result = self.inner.persist(records)
  result
}

///|
fn held_journal(block_write~ : Int32, signal_write~ : Int32) -> HeldJournal {
  {
    inner: @execution.MemoryBoardExecutionStore(),
    writes: 0,
    block_write,
    signal_write,
    writing: false,
    entered: @aqueue.Queue(kind=Unbounded),
    release: @aqueue.Queue(kind=Unbounded),
    signaled: @aqueue.Queue(kind=Unbounded),
  }
}

///|
async fn prepared_tasks(
  group : @async.TaskGroup[Unit],
  count : Int32,
) -> @backend.BoardBackend {
  let backend = @backend.BoardBackend(store=@store.MemoryBoardStore(), now_ms=() => {
    1234L
  })
  backend.attach(group)
  assert_true(backend.bootstrap_snapshot() is Ok(_))
  let mut revision = 0L
  for index in 1..<=count {
    let task = "task-\{index}"
    let attempt = "attempt-\{index}"
    assert_true(
      backend.handle_command({
        command_id: "create-\{index}",
        name: "board.task.create",
        expected_revision: revision,
        args: {
          "id": task,
          "title": "Explicit execution",
          "description": "",
          "priority": "normal",
          "definition_of_done": [],
          "dependencies": [],
        },
      }).accepted,
    )
    revision += 1L
    assert_true(
      backend.handle_command({
        command_id: "queue-\{index}",
        name: "board.attempt.queue",
        expected_revision: revision,
        args: { "id": attempt, "task_id": task, "kind": "execute" },
      }).accepted,
    )
    revision += 1L
  }
  backend
}

///|
fn slot_request(
  task~ : Int32,
  attempt~ : String,
  execution~ : Int32,
) -> @execution.BoardExecutionRequest {
  {
    task_id: "task-\{task}",
    attempt_id: attempt,
    execution_id: "exec-\{execution}",
    session_id: "session-exec-\{execution}",
    input: "Do explicit work",
    timeout_ms: None,
  }
}

///|
async test "multi-slot owners run overlapping gated executions on isolated drivers" {
  @async.with_task_group(group => {
    let backend = prepared_tasks(group, 2)
    let store = journal()
    let adapters : Array[ControlledAdapter] = []
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store~,
      adapter_factory=_ => {
        let adapter = controlled(block=true)
        adapters.push(adapter)
        adapter
      },
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    let first = owner
      .execute(slot_request(task=1, attempt="attempt-1", execution=1))
      .unwrap()
    let second = owner
      .execute(slot_request(task=2, attempt="attempt-2", execution=2))
      .unwrap()
    adapters[0].entered.get()
    adapters[1].entered.get()
    // Both slots passed the model gate and hold the journal Running phase at
    // the same time, each on its own driver.
    assert_eq(store.records.length(), 2)
    for record in store.records {
      assert_eq(record.phase, @execution.Running)
      assert_true(record.run is Some(_))
    }
    let state = backend.state().unwrap()
    assert_eq(state.attempts[0].status, @domain.Running)
    assert_eq(state.attempts[1].status, @domain.Running)
    assert_eq(adapters[0].calls, 1)
    assert_eq(adapters[1].calls, 1)
    adapters[0].release.put(())
    adapters[1].release.put(())
    assert_eq(first.wait().phase, @execution.Settled)
    assert_eq(second.wait().phase, @execution.Settled)
    let status = owner.status()
    assert_eq(status.capacity, 2)
    assert_eq(status.available_slots, 2)
    assert_true(status.active is None)
    assert_true(status.active_bindings.is_empty())
    assert_false(status.unresolved)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "exact-identity cancellation targets one slot and leaves other slots running" {
  @async.with_task_group(group => {
    let backend = prepared_tasks(group, 2)
    let adapters : Array[ControlledAdapter] = []
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store=journal(),
      adapter_factory=_ => {
        let adapter = controlled(block=true)
        adapters.push(adapter)
        adapter
      },
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    let first = owner
      .execute(slot_request(task=1, attempt="attempt-1", execution=1))
      .unwrap()
    let second = owner
      .execute(slot_request(task=2, attempt="attempt-2", execution=2))
      .unwrap()
    adapters[0].entered.get()
    adapters[1].entered.get()
    assert_true(owner.cancel("unknown") is Err(@execution.WrongExecution))
    assert_true(owner.cancel("exec-1") is Ok(_))
    assert_true(owner.cancel("exec-1") is Ok(_))
    assert_eq(first.wait().phase, @execution.Settled)
    assert_eq(first.wait().outcome, Some(@execution.Cancelled))
    let state = backend.state().unwrap()
    assert_eq(state.attempts[0].status, @domain.Cancelled)
    assert_eq(state.attempts[1].status, @domain.Running)
    assert_eq(adapters[1].effects, 1)
    assert_true(owner.cancel("exec-2") is Ok(_))
    assert_eq(second.wait().outcome, Some(@execution.Cancelled))
    assert_eq(backend.state().unwrap().attempts[1].status, @domain.Cancelled)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "held journal writes serialize other slots' settlement and admission behind one shared section" {
  @async.with_task_group(group => {
    let backend = prepared_tasks(group, 3)
    let store = held_journal(block_write=7, signal_write=11)
    let adapters : Array[ControlledAdapter] = []
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store~,
      adapter_factory=slot => {
        let adapter = if slot == 2 {
          controlled()
        } else {
          controlled(block=true)
        }
        adapters.push(adapter)
        adapter
      },
      max_concurrency=3,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    let first = owner
      .execute(slot_request(task=1, attempt="attempt-1", execution=31))
      .unwrap()
    adapters[0].entered.get()
    let second = owner
      .execute(slot_request(task=2, attempt="attempt-2", execution=32))
      .unwrap()
    adapters[1].entered.get()
    // Writes 1-6: reserve/run/running for both slots. The next write is the
    // first slot's Finished record; hold it in flight.
    assert_eq(store.writes, 6)
    adapters[0].release.put(())
    store.entered.get()
    assert_eq(store.writes, 7)
    // The second slot's settlement and a fresh admission must both wait for
    // the held write instead of interleaving journal records.
    adapters[1].release.put(())
    let third = group.spawn(() => {
      owner.execute(slot_request(task=3, attempt="attempt-3", execution=33))
    })
    assert_eq(store.writes, 7)
    store.release.put(())
    // Signal fires on write 11: first slot Settled (8), second Finished and
    // Settled (9, 10), only then the third admission reserved (11).
    store.signaled.get()
    let third_handle = match third.wait() {
      Ok(handle) => handle
      Err(_) => fail("third admission must serialize behind the held write")
    }
    assert_eq(first.wait().phase, @execution.Settled)
    assert_eq(second.wait().phase, @execution.Settled)
    // Settled slots free up, so the third admission recycled the first
    // slot's blocking driver: release it to finish its settlement.
    adapters[0].release.put(())
    assert_eq(third_handle.wait().phase, @execution.Settled)
    assert_eq(store.writes, 15)
    for record in @execution.BoardExecutionStore::load(store).unwrap() {
      assert_eq(record.phase, @execution.Settled)
    }
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "one slot's journal write failure poisons every slot without unsafe writes" {
  @async.with_task_group(group => {
    let backend = prepared_tasks(group, 3)
    let store = journal(fail_write=7)
    let adapters : Array[ControlledAdapter] = []
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store~,
      adapter_factory=_ => {
        let adapter = controlled(block=true)
        adapters.push(adapter)
        adapter
      },
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    let first = owner
      .execute(slot_request(task=1, attempt="attempt-1", execution=1))
      .unwrap()
    adapters[0].entered.get()
    let second = owner
      .execute(slot_request(task=2, attempt="attempt-2", execution=2))
      .unwrap()
    adapters[1].entered.get()
    adapters[0].release.put(())
    // Write 7 is the first slot's Finished record; its failure poisons the
    // whole owner.
    assert_eq(first.wait().phase, @execution.Unresolved)
    adapters[1].release.put(())
    assert_eq(second.wait().phase, @execution.Unresolved)
    // The failed write was the last one: the still-active second slot must
    // not write the journal again after the uncertainty.
    assert_eq(store.writes, 7)
    assert_true(
      owner.execute(slot_request(task=3, attempt="attempt-3", execution=3))
      is Err(@execution.NotReady),
    )
    assert_true(owner.status().unresolved)
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "recovered mixed v1 journals block globally while settled-only history admits fresh work" {
  let settled : @execution.BoardExecutionBinding = {
    task_id: "task-1",
    attempt_id: "attempt-1",
    execution_id: "exec-1",
    session_id: "session-exec-1",
    run: Some({ session_id: "session-exec-1", run_id: "run", turn_id: "turn", }),
    phase: @execution.Settled,
    outcome: Some(@execution.Completed),
  }
  let unresolved : @execution.BoardExecutionBinding = {
    task_id: "task-2",
    attempt_id: "attempt-2",
    execution_id: "exec-2",
    session_id: "session-exec-2",
    run: Some({ session_id: "session-exec-2", run_id: "run", turn_id: "turn", }),
    phase: @execution.Unresolved,
    outcome: Some(@execution.Failed),
  }
  let store = journal()
  assert_true(
    @execution.BoardExecutionStore::persist(store, [settled, unresolved])
    is Ok(_),
  )
  assert_eq(
    @execution.decode_execution_journal(
      @execution.encode_execution_journal([settled, unresolved]).unwrap(),
    ),
    Ok([settled, unresolved]),
  )
  @async.with_task_group(group => {
    let backend = prepared_tasks(group, 3)
    let adapters : Array[ControlledAdapter] = []
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store~,
      adapter_factory=_ => {
        let adapter = controlled()
        adapters.push(adapter)
        adapter
      },
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    let status = owner.status()
    assert_true(status.unresolved)
    assert_eq(status.capacity, 2)
    assert_eq(status.available_slots, 0)
    assert_true(
      owner.execute(slot_request(task=3, attempt="attempt-3", execution=3))
      is Err(@execution.NotReady),
    )
    assert_eq(adapters[0].calls, 0)
    assert_eq(adapters[1].calls, 0)
    assert_eq(owner.bindings(), [settled, unresolved])
    assert_true(owner.shutdown())
    backend.shutdown()
  })
  @async.with_task_group(group => {
    let backend = prepared_tasks(group, 3)
    let recovered = journal()
    assert_true(
      @execution.BoardExecutionStore::persist(recovered, [settled]) is Ok(_),
    )
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store=recovered,
      adapter_factory=_ => controlled(),
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    assert_false(owner.status().unresolved)
    // Settled identities stay globally unique across slots and restarts.
    assert_true(
      owner.execute(slot_request(task=1, attempt="attempt-1", execution=1))
      is Err(@execution.DuplicateIdentity),
    )
    assert_eq(
      owner
      .execute(slot_request(task=2, attempt="attempt-2", execution=2))
      .unwrap()
      .wait().phase,
      @execution.Settled,
    )
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "concurrent duplicate admission is rejected across slots by identity and active task" {
  @async.with_task_group(group => {
    let backend = prepared_tasks(group, 2)
    assert_true(
      backend.handle_command({
        command_id: "queue-extra",
        name: "board.attempt.queue",
        expected_revision: 4L,
        args: {
          "id": "attempt-1-extra",
          "task_id": "task-1",
          "kind": "execute",
        },
      }).accepted,
    )
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store=journal(),
      adapter_factory=_ => controlled(),
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    let same = [
      group.spawn(() => {
        owner.execute(slot_request(task=1, attempt="attempt-1", execution=1))
      }),
      group.spawn(() => {
        owner.execute(slot_request(task=1, attempt="attempt-1", execution=1))
      }),
    ]
    match (same[0].wait(), same[1].wait()) {
      (Ok(handle), Err(@execution.DuplicateIdentity | @execution.Busy))
      | (Err(@execution.DuplicateIdentity | @execution.Busy), Ok(handle)) =>
        assert_eq(handle.wait().phase, @execution.Settled)
      _ => fail("exactly one duplicate admission may reserve")
    }
    assert_eq(owner.bindings().length(), 1)
    assert_true(
      owner.execute(slot_request(task=1, attempt="attempt-1", execution=1))
      is Err(@execution.DuplicateIdentity),
    )
    let same_task = [
      group.spawn(() => {
        owner.execute(slot_request(task=1, attempt="attempt-1", execution=3))
      }),
      group.spawn(() => {
        owner.execute(
          slot_request(task=1, attempt="attempt-1-extra", execution=4),
        )
      }),
    ]
    match (same_task[0].wait(), same_task[1].wait()) {
      (Ok(handle), Err(@execution.DuplicateIdentity | @execution.Busy))
      | (Err(@execution.DuplicateIdentity | @execution.Busy), Ok(handle)) =>
        assert_eq(handle.wait().phase, @execution.Settled)
      _ => fail("one active execution per task across slots")
    }
    assert_eq(owner.bindings().length(), 2)
    assert_eq(
      owner
      .bindings()
      .filter(binding => binding.attempt_id == "attempt-1")
      .length(),
      1,
    )
    assert_true(owner.shutdown())
    backend.shutdown()
  })
}

///|
async test "slot construction validates concurrency calls factory once per slot and keeps single-slot defaults" {
  @async.with_task_group(group => {
    let backend = prepared_tasks(group, 1)
    let calls : Array[Int32] = []
    for invalid in [0, 9] {
      assert_true(
        @execution.BoardExecutionOwner::with_slots(
          backend~,
          store=journal(),
          adapter_factory=slot => {
            calls.push(slot)
            controlled()
          },
          max_concurrency=invalid,
        )
        is Err(@execution.InvalidRequest),
      )
    }
    assert_true(calls.is_empty())
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store=journal(),
      adapter_factory=slot => {
        calls.push(slot)
        controlled()
      },
      max_concurrency=3,
    ).unwrap()
    assert_eq(calls, [0, 1, 2])
    let status = owner.status()
    assert_eq(status.capacity, 3)
    assert_eq(status.available_slots, 3)
    assert_true(status.active_bindings.is_empty())
    assert_true(owner.attach(group) is Ok(_))
    // The historical constructor stays the exact one-slot owner.
    let single = @execution.BoardExecutionOwner(
      backend~,
      adapter=controlled(),
      store=journal(),
    )
    assert_eq(single.status().capacity, 1)
    assert_eq(single.status().available_slots, 1)
    assert_true(single.attach(group) is Ok(_))
    let one = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store=journal(),
      adapter_factory=_ => controlled(),
    ).unwrap()
    assert_eq(one.status().capacity, 1)
    assert_true(one.attach(group) is Ok(_))
    let handle = one
      .execute(slot_request(task=1, attempt="attempt-1", execution=1))
      .unwrap()
    assert_eq(one.status().available_slots, 0)
    assert_eq(one.status().active_bindings.length(), 1)
    assert_eq(handle.wait().phase, @execution.Settled)
    assert_eq(one.status().available_slots, 1)
    assert_true(one.shutdown())
    assert_true(owner.shutdown())
    assert_true(single.shutdown())
    backend.shutdown()
  })
}

///|
async test "shutdown cancels every slot and bounds the overall join while retaining ownership" {
  @async.with_task_group(group => {
    let backend = prepared_tasks(group, 2)
    let drivers : Array[SlowCleanupAdapter] = []
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store=journal(),
      adapter_factory=_ => {
        let driver : SlowCleanupAdapter = {
          entered: @aqueue.Queue(kind=Unbounded),
          cleaning: @aqueue.Queue(kind=Unbounded),
          release: @aqueue.Queue(kind=Unbounded),
        }
        drivers.push(driver)
        driver
      },
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    let first = owner
      .execute(slot_request(task=1, attempt="attempt-1", execution=1))
      .unwrap()
    let second = owner
      .execute(slot_request(task=2, attempt="attempt-2", execution=2))
      .unwrap()
    drivers[0].entered.get()
    drivers[1].entered.get()
    assert_false(owner.shutdown(timeout_ms=30))
    drivers[0].cleaning.get()
    drivers[1].cleaning.get()
    let status = owner.status()
    assert_true(status.closed)
    assert_eq(status.active_bindings.length(), 2)
    assert_eq(status.available_slots, 0)
    assert_true(
      owner.execute(slot_request(task=1, attempt="attempt-1", execution=3))
      is Err(@execution.Closed),
    )
    let state = backend.state().unwrap()
    assert_eq(state.attempts[0].status, @domain.Running)
    assert_eq(state.attempts[1].status, @domain.Running)
    drivers[0].release.put(())
    drivers[1].release.put(())
    assert_eq(first.wait().outcome, Some(@execution.Cancelled))
    assert_eq(second.wait().outcome, Some(@execution.Cancelled))
    assert_true(owner.shutdown())
    let settled = backend.state().unwrap()
    assert_eq(settled.attempts[0].status, @domain.Cancelled)
    assert_eq(settled.attempts[1].status, @domain.Cancelled)
    backend.shutdown()
  })
}
