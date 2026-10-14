///|
/// Typed pinned candidate; record literals do not infer at optional labels.
fn orch_pin(
  task_id : String,
  attempt_id : String,
) -> @orchestration.ExecutionCandidate {
  { task_id, attempt_id, }
}

///|
/// Per-slot driver for multi-slot owners: identical behavior to OrchAdapter
/// with its own block/delay flags while sharing counters and gates.
struct OrchSlotAdapter {
  shared : OrchAdapter
  block : Bool
  delay_gate : Bool
}

///|
fn orch_slot_adapter(
  shared : OrchAdapter,
  block~ : Bool = false,
  delay_gate~ : Bool = false,
) -> OrchSlotAdapter {
  { shared, block, delay_gate, }
}

///|
impl @execution.BoardExecutionAdapter for OrchSlotAdapter with fn ready(self) {
  self.shared.available
}

///|
impl @execution.BoardExecutionAdapter for OrchSlotAdapter with fn run(
  self,
  request,
  start,
) {
  self.shared.calls += 1
  self.shared.seen_timeout = request.timeout_ms
  self.shared.before_gate.put(())
  if self.delay_gate {
    self.shared.gate_release.get()
  }
  if !start({
      session_id: request.session_id,
      run_id: "run-" + request.execution_id,
      turn_id: "turn",
    }) {
    return @execution.Failed
  }
  self.shared.effects += 1
  self.shared.entered.put(())
  if self.block {
    self.shared.release.get()
  }
  @execution.Completed
}

///|
fn orch_slots_owner(
  backend : @backend.BoardBackend,
  journal : OrchJournal,
  shared : OrchAdapter,
  slots~ : Int32,
) -> @execution.BoardExecutionOwner raise {
  match
    @execution.BoardExecutionOwner::with_slots(
      backend~,
      store=journal,
      adapter_factory=_ => {
        orch_slot_adapter(
          shared,
          block=shared.block,
          delay_gate=shared.delay_gate,
        )
      },
      max_concurrency=slots,
    ) {
    Ok(owner) => owner
    Err(_) => fail("expected a multi-slot owner")
  }
}

///|
async test "parallel owner capacity admits independent tasks until slots are exhausted" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    orch_queued_task(backend, id="task-b")
    let adapter = orch_adapter(block=true)
    let journal = orch_journal()
    let owner = orch_slots_owner(backend, journal, adapter, slots=2)
    assert_true(owner.attach(group) is Ok(_))
    let scheduler = orch_facade(owner, orch_resolver())
    let first = orch_handle(scheduler.dispatch_next())
    adapter.entered.get()
    let second = orch_handle(scheduler.dispatch_next())
    adapter.entered.get()
    let status = scheduler.status().unwrap()
    assert_eq(status.owner.active_bindings.length(), 2)
    assert_eq(status.owner.available_slots, 0)
    assert_false(status.admission_enabled)
    assert_eq(status.plan.eligible.length(), 0)
    for row in status.plan.blocked {
      assert_true(row.reasons.contains(@orchestration.ExecutionActive))
    }
    assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
    assert_eq(adapter.effects, 2)
    adapter.release.put(())
    adapter.release.put(())
    assert_eq(first.wait().phase, @execution.Settled)
    assert_eq(second.wait().phase, @execution.Settled)
    let done = scheduler.status().unwrap()
    assert_eq(done.owner.active_bindings.length(), 0)
    assert_eq(done.owner.available_slots, 2)
    assert_true(done.admission_enabled)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "free capacity keeps independent tasks eligible while the active task is suppressed" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    orch_queued_task(backend, id="task-b")
    let adapter = orch_adapter(block=true)
    let owner = orch_slots_owner(backend, orch_journal(), adapter, slots=2)
    assert_true(owner.attach(group) is Ok(_))
    let resolver = orch_resolver()
    let scheduler = orch_facade(owner, resolver)
    let handle = orch_handle(scheduler.dispatch_next())
    adapter.entered.get()
    let plan = scheduler.plan().unwrap()
    assert_eq(plan.eligible, [
      { task_id: "task-b", attempt_id: "attempt-task-b", },
    ])
    assert_eq(plan.blocked.length(), 1)
    assert_eq(plan.blocked[0].task_id, "task")
    assert_eq(plan.blocked[0].reasons, [@orchestration.NoQueuedExecuteAttempt])
    let status = scheduler.status().unwrap()
    assert_eq(status.owner.active_bindings.length(), 1)
    assert_eq(status.owner.available_slots, 1)
    assert_true(status.admission_enabled)
    // Fresh admission of the independent pinned candidate on the free slot.
    let second = orch_handle(
      scheduler.dispatch_next(
        task_scope=["task-b"],
        candidate=orch_pin("task-b", "attempt-task-b"),
      ),
    )
    adapter.entered.get()
    assert_eq(resolver.calls, 2)
    adapter.release.put(())
    adapter.release.put(())
    assert_eq(handle.wait().phase, @execution.Settled)
    assert_eq(second.wait().phase, @execution.Settled)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "an active Task blocks duplicate dispatch but history still allows a fresh attempt" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    orch_queued_task(backend, id="task-b")
    let adapter = orch_adapter(block=true, delay_gate=true)
    let owner = orch_slots_owner(backend, orch_journal(), adapter, slots=2)
    assert_true(owner.attach(group) is Ok(_))
    let resolver = orch_resolver()
    let scheduler = orch_facade(owner, resolver)
    let handle = orch_handle(scheduler.dispatch_next())
    adapter.before_gate.get()
    // Reserved binding, Board attempt still Queued: the same Task is
    // suppressed despite a free slot, so a duplicate wave entry cannot run.
    assert_eq(
      scheduler.status().unwrap().owner.active.unwrap().phase,
      @execution.Reserved,
    )
    let plan = scheduler.plan().unwrap()
    assert_eq(plan.eligible, [
      { task_id: "task-b", attempt_id: "attempt-task-b", },
    ])
    // The reserved identity is both active and already used by history.
    assert_eq(plan.blocked, [
      {
        task_id: "task",
        attempt_id: Some("attempt"),
        reasons: [
          @orchestration.ExecutionActive,
          @orchestration.IdentityAlreadyUsed,
        ],
      },
    ])
    assert_true(
      scheduler.dispatch_next(task_scope=["task"])
      is Ok(@orchestration.Blocked(_)),
    )
    assert_true(
      scheduler.dispatch_next(
        task_scope=["task"],
        candidate=orch_pin("task", "attempt"),
      )
      is Ok(@orchestration.StalePlan(_)),
    )
    // Only the original admission ever resolved input.
    assert_eq(resolver.calls, 1)
    assert_eq(adapter.effects, 0)
    adapter.gate_release.put(())
    adapter.release.put(())
    assert_eq(handle.wait().phase, @execution.Settled)
    // The settled Attempt ID stays blocked by identity history.
    let after = scheduler.plan().unwrap()
    assert_eq(after.eligible, [
      { task_id: "task-b", attempt_id: "attempt-task-b", },
    ])
    assert_eq(after.blocked[0].task_id, "task")
    assert_eq(after.blocked[0].reasons, [@orchestration.NoQueuedExecuteAttempt])
    assert_true(
      scheduler.dispatch_next(
        task_scope=["task"],
        candidate=orch_pin("task", "attempt"),
      )
      is Ok(@orchestration.StalePlan(_)),
    )
    assert_eq(resolver.calls, 1)
    // A newly queued Attempt for the same Task is admissible again.
    orch_command(backend, "board.attempt.queue", {
      "id": "attempt-2",
      "task_id": "task",
      "kind": "execute",
    })
    assert_true(
      scheduler.plan().unwrap().eligible.contains({
        task_id: "task",
        attempt_id: "attempt-2",
      }),
    )
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "pinned wave candidate admits its exact attempt and rejects a consumed one" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    orch_queued_task(backend, id="task-b")
    let adapter = orch_adapter(block=true)
    let owner = orch_slots_owner(backend, orch_journal(), adapter, slots=2)
    assert_true(owner.attach(group) is Ok(_))
    let resolver = orch_resolver()
    let scheduler = orch_facade(owner, resolver)
    let plan = scheduler.plan().unwrap()
    assert_eq(plan.eligible[0], { task_id: "task", attempt_id: "attempt", })
    let first = orch_handle(
      scheduler.dispatch_next(candidate=orch_pin("task", "attempt")),
    )
    adapter.entered.get()
    // Mid-wave: the candidate's Attempt is consumed elsewhere and a rival
    // higher-ranked Task appears with a replacement Attempt.
    orch_command(backend, "board.attempt.start", { "id": "attempt-task-b" })
    orch_command(backend, "board.attempt.finish", {
      "id": "attempt-task-b",
      "outcome": "failed",
    })
    orch_command(backend, "board.attempt.queue", {
      "id": "attempt-task-b-2",
      "task_id": "task-b",
      "kind": "execute",
    })
    orch_queued_task(backend, id="task-z", priority="critical")
    assert_eq(resolver.calls, 1)
    // The consumed Attempt is never silently replaced by the queued rival.
    assert_true(
      scheduler.dispatch_next(
        task_scope=["task-b"],
        candidate=orch_pin("task-b", "attempt-task-b"),
      )
      is Ok(@orchestration.StalePlan(_)),
    )
    assert_eq(resolver.calls, 1)
    assert_eq(adapter.effects, 1)
    // The exact surviving candidate is admitted even though it no longer leads
    // the unscoped plan.
    let second = orch_handle(
      scheduler.dispatch_next(
        task_scope=["task-b"],
        candidate=orch_pin("task-b", "attempt-task-b-2"),
      ),
    )
    adapter.entered.get()
    assert_eq(resolver.calls, 2)
    adapter.release.put(())
    adapter.release.put(())
    assert_eq(first.wait().phase, @execution.Settled)
    assert_eq(second.wait().phase, @execution.Settled)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "the model gate ignores active bindings while revalidating candidate and scope" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    orch_queued_task(backend, id="task-b")
    let adapter = orch_adapter(block=true)
    let owner = orch_slots_owner(backend, orch_journal(), adapter, slots=2)
    assert_true(owner.attach(group) is Ok(_))
    let scheduler = orch_facade(owner, orch_resolver())
    let first = orch_handle(scheduler.dispatch_next())
    adapter.entered.get()
    // The second run passes its own reserved binding and the sibling active
    // binding at the gate: only the pure planner and its scope are consulted.
    let second = orch_handle(
      scheduler.dispatch_next(
        task_scope=["task-b"],
        candidate=orch_pin("task-b", "attempt-task-b"),
      ),
    )
    adapter.entered.get()
    assert_eq(adapter.effects, 2)
    adapter.release.put(())
    adapter.release.put(())
    assert_eq(first.wait().phase, @execution.Settled)
    assert_eq(second.wait().phase, @execution.Settled)
    let state = backend.state().unwrap()
    assert_eq(state.attempts.length(), 2)
    for attempt in state.attempts {
      assert_eq(attempt.status, @domain.Succeeded)
    }
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "default slot owner preserves the single execution S4B behavior" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    let adapter = orch_adapter(block=true)
    let owner = match
      @execution.BoardExecutionOwner::with_slots(
        backend~,
        store=orch_journal(),
        adapter_factory=_ => orch_slot_adapter(adapter, block=true),
      ) {
      Ok(owner) => owner
      Err(_) => fail("expected a default slot owner")
    }
    assert_true(owner.attach(group) is Ok(_))
    let scheduler = orch_facade(owner, orch_resolver())
    let handle = orch_handle(scheduler.dispatch_next())
    adapter.entered.get()
    let status = scheduler.status().unwrap()
    assert_eq(status.owner.capacity, 1)
    assert_eq(status.owner.active_bindings.length(), 1)
    assert_eq(status.owner.available_slots, 0)
    assert_false(status.admission_enabled)
    assert_eq(status.plan.eligible.length(), 0)
    assert_true(
      status.plan.blocked[0].reasons.contains(@orchestration.ExecutionActive),
    )
    assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
    assert_eq(adapter.effects, 1)
    adapter.release.put(())
    assert_eq(handle.wait().phase, @execution.Settled)
    assert_eq(scheduler.status().unwrap().owner.available_slots, 1)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}
