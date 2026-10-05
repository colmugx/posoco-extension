///|
fn enqueue_mutation(
  coordinator : BoardCoordinator,
  command : @domain.BoardCommand,
) -> SubmissionCompletion raise {
  let completion : SubmissionCompletion = @aqueue.Queue(
    kind=@aqueue.Blocking(1),
  )
  assert_true(
    coordinator.actor.unwrap().tell(Submit(command, completion)) is Ok(_),
  )
  completion
}

///|
async test "blocked persistence hides revision 6 and does not complete public submit" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let initial = snapshot_of(5L, [task_record("old", @domain.Created, 10L)], [])
    store.loads.push_back(LoadOk(load_of(initial)))
    let coordinator = ready_scripted(group, store)
    let gate = new_gate()
    store.persists.push_back(StepGate(gate))
    let finished = Ref(false)
    let submitted = group.spawn(() => {
      let outcome = coordinator.submit(command=c_create("new", 5L))
      finished.val = true
      outcome
    })
    gate.entered.get()
    assert_false(finished.val)
    assert_eq(coordinator.revision(), Ok(5L))
    assert_eq(coordinator.snapshot(), Ok(initial))
    assert_eq(coordinator.tasks().unwrap().length(), 1)
    assert_eq(coordinator.task(id=cid("new")), Ok(None))
    assert_false(finished.val)
    gate.release.put(())
    assert_true(submitted.wait() is Ok(_))
    assert_true(finished.val)
    assert_eq(coordinator.revision(), Ok(6L))
    coordinator.shutdown()
  })
}

///|
async test "blocked failed first transaction reproposes queued same-revision commands in FIFO" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = ready_scripted(group, store)
    let gate = new_gate()
    store.persists.push_back(
      StepGatedFailure(gate, @store.Injected(@store.JournalFsync)),
    )
    let a = enqueue_mutation(coordinator, c_create("a", 0L))
    gate.entered.get()
    let b = enqueue_mutation(coordinator, c_create("b", 0L))
    let c = enqueue_mutation(coordinator, c_create("c", 1L))
    // This ask only proves FIFO admission, not persistence completion.
    assert_eq(coordinator.revision(), Ok(0L))
    assert_eq(store.persist_attempts, 1)
    assert_eq(b.try_get(), None)
    assert_eq(c.try_get(), None)
    gate.release.put(())
    assert_eq(a.get(), Err(PersistFailed(@store.Injected(@store.JournalFsync))))
    assert_true(b.get() is Ok(_))
    assert_true(c.get() is Ok(_))
    assert_eq(store.committed_writes.map(write => write.revision), [1L, 2L])
    assert_eq(coordinator.tasks().unwrap().map(task => task.id.value), [
      "b", "c",
    ])
    coordinator.shutdown()
  })
}

///|
async test "recovery persistence completes before startup exposes recovered revision" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let initial = snapshot_of(9L, [task_record("task", @domain.Running, 10L)], [
      attempt_record("attempt", "task", @domain.Running),
    ])
    store.loads.push_back(LoadOk(load_of(initial)))
    let gate = new_gate()
    store.persists.push_back(StepGate(gate))
    let coordinator = scripted_coordinator(store, now_ms=() => 99L)
    coordinator.attach(group~)
    let ready_finished = Ref(false)
    let waiter = group.spawn(() => {
      let outcome = coordinator.wait_ready()
      ready_finished.val = true
      outcome
    })
    gate.entered.get()
    assert_eq(coordinator.status(), Loading)
    assert_rejected(coordinator.snapshot(), Initializing)
    assert_rejected(coordinator.revision(), Initializing)
    assert_false(ready_finished.val)
    gate.release.put(())
    assert_true(waiter.wait() is Ok(_))
    assert_eq(coordinator.revision(), Ok(10L))
    assert_eq(store.durable.revision, 10L)
    assert_eq(
      coordinator.task(id=cid("task")).unwrap().unwrap().stage,
      @domain.Suspended,
    )
    assert_eq(
      coordinator.attempt(id=caid("attempt")).unwrap().unwrap().status,
      @domain.Interrupted,
    )
    coordinator.shutdown()
  })
}

///|
async test "stale reload ticket cannot settle a later reconciliation" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = ready_scripted(group, store)
    store.persists.push_back(StepUncertain("first"))
    store.loads.push_back(LoadOk(load_of(@store.empty_snapshot())))
    assert_eq(
      coordinator.submit(command=c_create("a", 0L)),
      Err(DurabilityUncertain("first")),
    )
    let gate = new_gate()
    store.persists.push_back(StepUncertain("second"))
    store.loads.push_back(LoadGate(gate, load_of(@store.empty_snapshot())))
    let pending = enqueue_mutation(coordinator, c_create("b", 0L))
    gate.entered.get()
    let actor = coordinator.actor.unwrap()
    assert_true(
      actor.tell(
        Worker(Reloaded(ticket=1L, outcome=Ok(snapshot_of(42L, [], [])))),
      )
      is Ok(_),
    )
    assert_rejected(coordinator.revision(), Initializing)
    assert_eq(coordinator.status(), Reconciling)
    assert_eq(pending.try_get(), None)
    gate.release.put(())
    assert_eq(pending.get(), Err(DurabilityUncertain("second")))
    assert_eq(coordinator.revision(), Ok(0L))
    coordinator.shutdown()
  })
}

///|
async test "shutdown before attach reports Stopped and subsequent attach restores" {
  let coordinator = BoardCoordinator()
  coordinator.shutdown()
  assert_eq(coordinator.status(), Stopped)
  assert_rejected(coordinator.wait_ready(), Closed)
  @async.with_task_group(group => {
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    coordinator.shutdown()
  })
}

///|
async test "cancelled ready waiter withdraws from actor while load remains blocked" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let gate = new_gate()
    store.loads.push_back(LoadGate(gate, load_of(@store.empty_snapshot())))
    let coordinator = scripted_coordinator(store)
    coordinator.attach(group~)
    gate.entered.get()
    let entered = @aqueue.Queue(kind=@aqueue.Blocking(1))
    let waiter = group.spawn(() => {
      entered.put(())
      coordinator.wait_ready()
    })
    entered.get()
    assert_rejected(coordinator.revision(), Initializing)
    waiter.cancel()
    let _ = waiter.wait() catch { _ => Err(Closed) }
    assert_rejected(coordinator.revision(), Initializing)
    // Test the exact cancellation fold independently of async scheduling.
    let state = CoordinatorState::initial()
    let queue = @aqueue.Queue(kind=@aqueue.Blocking(1))
    coordinator_add_waiter(state, 1L, queue)
    assert_eq(state.waiters.length(), 1)
    coordinator_cancel_waiter(state, 1L)
    assert_eq(state.waiters.length(), 0)
    gate.release.put(())
    assert_true(coordinator.wait_ready() is Ok(_))
    coordinator.shutdown()
  })
}

///|
async test "cancelled and concurrent shutdowns wait for active persistence before reattach" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = ready_scripted(group, store)
    let gate = new_gate()
    store.persists.push_back(StepGate(gate))
    let submit = enqueue_mutation(coordinator, c_create("a", 0L))
    gate.entered.get()
    let started = @aqueue.Queue(kind=@aqueue.Blocking(1))
    let first = group.spawn(() => {
      started.put(())
      coordinator.shutdown()
    })
    started.get()
    assert_rejected(coordinator.revision(), Closed)
    first.cancel()
    let second = group.spawn(() => coordinator.shutdown())
    assert_eq(coordinator.status(), Stopping)
    assert_rejected(coordinator.submit(command=c_create("b", 1L)), Closed)
    gate.release.put(())
    assert_true(submit.get() is Ok(_))
    let _ = first.wait() catch { _ => () }
    second.wait()
    assert_eq(coordinator.status(), Stopped)
    assert_eq(store.durable.revision, 1L)
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    assert_eq(coordinator.revision(), Ok(1L))
    assert_true(coordinator.submit(command=c_create("b", 1L)) is Ok(_))
    coordinator.shutdown()
  })
}

///|
async test "shutdown waits for uncertainty reconciliation and settles caller explicitly" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = ready_scripted(group, store)
    let proposal = @domain.BoardDomain::propose(
      @domain.BoardState(),
      c_create("a", 0L),
    ).unwrap()
    let landed = proposal.next_state.snapshot()
    let gate = new_gate()
    store.persists.push_back(StepUncertain("rename landed"))
    store.loads.push_back(LoadGate(gate, load_of(landed)))
    let mutation = enqueue_mutation(coordinator, c_create("a", 0L))
    gate.entered.get()
    store.durable = landed
    let deferred = enqueue_mutation(coordinator, c_create("b", 1L))
    assert_rejected(coordinator.revision(), Initializing)
    let started = @aqueue.Queue(kind=@aqueue.Blocking(1))
    let teardown = group.spawn(() => {
      started.put(())
      coordinator.shutdown()
    })
    started.get()
    assert_eq(coordinator.status(), Stopping)
    assert_eq(mutation.try_get(), None)
    gate.release.put(())
    assert_eq(mutation.get(), Err(DurabilityUncertain("rename landed")))
    assert_eq(deferred.get(), Err(Closed))
    teardown.wait()
    assert_eq(coordinator.status(), Stopped)
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    assert_eq(coordinator.revision(), Ok(1L))
    coordinator.shutdown()
  })
}

///|
priv suberror UnexpectedPersistError {
  AfterReplacement
}

///|
priv struct RaisingStore {
  inner : @store.MemoryBoardStore
  mut raise_once : Bool
}

///|
impl @store.BoardStore for RaisingStore with fn load(self) {
  self.inner.load()
}

///|
impl @store.BoardStore for RaisingStore with fn persist(self, snapshot, events) {
  let outcome = self.inner.persist(snapshot, events)
  if self.raise_once {
    self.raise_once = false
    raise AfterReplacement
  }
  outcome
}

///|
async test "raised store error reconciles unknown write boundary without host fail-fast" {
  @async.with_task_group(group => {
    let store : RaisingStore = {
      inner: @store.MemoryBoardStore(),
      raise_once: true,
    }
    let coordinator = BoardCoordinator(store~, now_ms=() => 1L)
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    assert_true(
      coordinator.submit(command=c_create("a", 0L))
      is Err(DurabilityUncertain(_)),
    )
    assert_eq(coordinator.status(), Ready)
    assert_eq(coordinator.revision(), Ok(1L))
    assert_true(coordinator.submit(command=c_create("b", 1L)) is Ok(_))
    assert_eq(coordinator.revision(), Ok(2L))
    coordinator.shutdown()
  })
}
