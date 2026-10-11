///|
/// Creates one Ready task with a queued Execute Attempt through public backend
/// commands, sharing the shape of orch_board's base task.
async fn orch_queued_task(
  backend : @backend.BoardBackend,
  id~ : String,
  priority? : String = "normal",
  dependency? : String = "",
) -> Unit {
  let dependencies : Json = if dependency == "" { [] } else { [dependency] }
  orch_command(backend, "board.task.create", {
    "id": id,
    "title": "Task \{id}",
    "description": "",
    "priority": priority,
    "definition_of_done": [],
    "dependencies": dependencies,
  })
  for stage in ["refining", "ready"] {
    orch_command(backend, "board.task.move", { "id": id, "to": stage })
  }
  orch_command(backend, "board.attempt.queue", {
    "id": "attempt-\{id}",
    "task_id": id,
    "kind": "execute",
  })
}

///|
async test "task scope skips a higher ranked outsider in plan status and dispatch" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    orch_queued_task(backend, id="outsider", priority="critical")
    let adapter = orch_adapter()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=orch_journal(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let resolver = orch_resolver()
    let scheduler = orch_facade(owner, resolver)
    let full = scheduler.plan().unwrap()
    assert_eq(full.eligible[0].task_id, "outsider")
    let scoped = scheduler.plan(task_scope=["task"]).unwrap()
    assert_eq(scoped.revision, full.revision)
    assert_eq(scoped.eligible, [{ task_id: "task", attempt_id: "attempt", }])
    assert_eq(scoped.blocked, [])
    // Blocked rows outside the scope disappear with their reasons.
    resolver.hint = @orchestration.Missing
    let blocked = scheduler.plan(task_scope=["task"]).unwrap()
    assert_eq(blocked.eligible, [])
    assert_eq(blocked.blocked.length(), 1)
    assert_eq(blocked.blocked[0].task_id, "task")
    resolver.hint = @orchestration.Available
    assert_eq(scheduler.status(task_scope=["task"]).unwrap().plan, scoped)
    let handle = orch_handle(scheduler.dispatch_next(task_scope=["task"]))
    // The higher ranked outsider is never inspected for input resolution.
    assert_eq(resolver.calls, 1)
    adapter.entered.get()
    assert_eq(scheduler.status().unwrap().owner.active.unwrap().task_id, "task")
    adapter.release.put(())
    assert_eq(handle.wait().phase, @execution.Settled)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "a false dispatch admission guard stops before resolution or any effect" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    let adapter = orch_adapter()
    let journal = orch_journal()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    let resolver = orch_resolver()
    let scheduler = orch_facade(owner, resolver)
    assert_true(
      scheduler.dispatch_next(admission_guard=() => false)
      is Err(@orchestration.AdmissionStopped),
    )
    assert_true(
      scheduler.dispatch_next(task_scope=["task"], admission_guard=() => false)
      is Err(@orchestration.AdmissionStopped),
    )
    assert_eq(resolver.calls, 0)
    assert_eq(journal.writes, 0)
    assert_eq(adapter.calls, 0)
    assert_true(owner.bindings().is_empty())
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "admission guard withdrawal after resolution and at reservation stops before effects" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    let adapter = orch_adapter()
    let journal = orch_journal()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    let resolver = orch_resolver()
    let scheduler = orch_facade(owner, resolver)
    let mut permits = 1
    let late = () => {
      let allowed = permits > 0
      permits -= 1
      allowed
    }
    match scheduler.dispatch_next(admission_guard=late) {
      Err(@orchestration.AdmissionStopped) => ()
      _ => fail("guard false after resolution must stop before reservation")
    }
    // Authorized before resolution only: input was resolved once, then the
    // post-resolution recheck denied it without reserving or executing.
    assert_eq(resolver.calls, 1)
    assert_eq(journal.writes, 0)
    assert_eq(adapter.calls, 0)
    assert_true(owner.bindings().is_empty())
    permits = 2
    match scheduler.dispatch_next(admission_guard=late) {
      Err(@orchestration.AdmissionStopped) => ()
      _ => fail("guard false at reservation must stop before journalling")
    }
    // Authorized before and after resolution, denied inside the owner's
    // protected reservation read: still no journal write and no execution.
    assert_eq(resolver.calls, 2)
    assert_eq(journal.writes, 0)
    assert_eq(adapter.calls, 0)
    assert_true(owner.bindings().is_empty())
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "admission guard withdrawal at the model gate blocks provider effects" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    let adapter = orch_adapter(delay_gate=true)
    let journal = orch_journal()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    let resolver = orch_resolver()
    let scheduler = orch_facade(owner, resolver)
    let mut open = true
    let handle = orch_handle(
      scheduler.dispatch_next(admission_guard=() => open),
    )
    // Reservation succeeded, so the exact admitted run is returned; the driver
    // is held before its start gate while the guard is withdrawn.
    adapter.before_gate.get()
    open = false
    adapter.gate_release.put(())
    let binding = handle.wait()
    assert_eq(binding.phase, @execution.Unresolved)
    assert_eq(binding.outcome, Some(@execution.Failed))
    assert_eq(adapter.calls, 1)
    assert_eq(adapter.effects, 0)
    assert_eq(journal.writes, 3)
    assert_true(scheduler.status().unwrap().owner.unresolved)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "execution timeout ceiling caps the resolver timeout and rejects nonpositive" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    orch_queued_task(backend, id="task-a")
    orch_queued_task(backend, id="task-b")
    orch_queued_task(backend, id="task-c")
    orch_queued_task(backend, id="task-d")
    let adapter = orch_adapter()
    let journal = orch_journal()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    let resolver = orch_resolver()
    let scheduler = orch_facade(owner, resolver)
    assert_true(
      scheduler.dispatch_next(execution_timeout_ms=0)
      is Err(@orchestration.InvalidDispatch),
    )
    assert_true(
      scheduler.dispatch_next(execution_timeout_ms=-5)
      is Err(@orchestration.InvalidDispatch),
    )
    assert_eq(resolver.calls, 0)
    assert_eq(journal.writes, 0)
    assert_eq(adapter.calls, 0)
    // The ceiling reduces a larger resolver timeout.
    resolver.timeout_ms = Some(9000)
    let capped = orch_handle(
      scheduler.dispatch_next(task_scope=["task-a"], execution_timeout_ms=50),
    )
    assert_eq(capped.wait().phase, @execution.Settled)
    assert_eq(adapter.seen_timeout, Some(50))
    // A ceiling alone bounds a resolver that supplies no timeout.
    resolver.timeout_ms = None
    let imposed = orch_handle(
      scheduler.dispatch_next(task_scope=["task-b"], execution_timeout_ms=70),
    )
    assert_eq(imposed.wait().phase, @execution.Settled)
    assert_eq(adapter.seen_timeout, Some(70))
    // A smaller resolver timeout stays unchanged under the ceiling.
    resolver.timeout_ms = Some(30)
    let smaller = orch_handle(
      scheduler.dispatch_next(task_scope=["task-c"], execution_timeout_ms=70),
    )
    assert_eq(smaller.wait().phase, @execution.Settled)
    assert_eq(adapter.seen_timeout, Some(30))
    // Without a ceiling the resolver timeout passes through unchanged (S4B).
    resolver.timeout_ms = Some(9000)
    let passthrough = orch_handle(
      scheduler.dispatch_next(task_scope=["task-d"]),
    )
    assert_eq(passthrough.wait().phase, @execution.Settled)
    assert_eq(adapter.seen_timeout, Some(9000))
    assert_eq(resolver.calls, 4)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "defaults preserve S4B and scope arrays stay detached per call" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    orch_queued_task(backend, id="outsider", priority="critical")
    let adapter = orch_adapter()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=orch_journal(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let resolver = orch_resolver()
    let scheduler = orch_facade(owner, resolver)
    // Omitted scope: the unscoped S4B order with the higher rank first.
    assert_eq(scheduler.plan().unwrap().eligible[0].task_id, "outsider")
    // The scope array is copied once per call: mutating it while a dispatch is
    // in flight cannot change that dispatch's scope.
    let scope = ["task"]
    let call = group.spawn(() => scheduler.dispatch_next(task_scope=scope))
    resolver.entered.get()
    scope.clear()
    scope.push("outsider")
    resolver.release.put(())
    let handle = orch_handle(call.wait())
    adapter.entered.get()
    assert_eq(scheduler.status().unwrap().owner.active.unwrap().task_id, "task")
    adapter.release.put(())
    assert_eq(handle.wait().phase, @execution.Settled)
    // An explicit empty scope authorizes nothing and never resolves.
    assert_true(scheduler.plan(task_scope=[]).unwrap().eligible.is_empty())
    assert_true(
      scheduler.dispatch_next(task_scope=[]) is Ok(@orchestration.Blocked(_)),
    )
    assert_eq(resolver.calls, 1)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "scope filtering still evaluates dependencies outside the scope" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    // The dependency stays Created outside the scope and is never queued.
    orch_command(backend, "board.task.create", {
      "id": "dep",
      "title": "Task dep",
      "description": "",
      "priority": "normal",
      "definition_of_done": [],
      "dependencies": [],
    })
    orch_queued_task(backend, id="scoped", dependency="dep")
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=orch_adapter(),
      store=orch_journal(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let scheduler = orch_facade(owner, orch_resolver())
    let plan = scheduler.plan(task_scope=["scoped"]).unwrap()
    assert_eq(plan.eligible, [])
    // The full snapshot planner still gates the scoped task on the out-of-scope
    // dependency, and the out-of-scope rows themselves are filtered away.
    assert_eq(plan.blocked, [
      {
        task_id: "scoped",
        attempt_id: Some("attempt-scoped"),
        reasons: [@orchestration.DependencyNotDone("dep")],
      },
    ])
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "board_state exposes the same owner's detached snapshot" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=orch_adapter(),
      store=orch_journal(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let scheduler = orch_facade(owner, orch_resolver())
    let state = scheduler.board_state().unwrap()
    assert_eq(state, backend.state().unwrap())
    // Mutating the detached result cannot affect the authoritative Board.
    state.tasks.clear()
    state.attempts.clear()
    assert_eq(scheduler.board_state().unwrap().tasks.length(), 1)
    assert_eq(scheduler.board_state().unwrap().attempts.length(), 1)
    assert_true(scheduler.shutdown())
    backend.shutdown()
    assert_true(scheduler.board_state() is Err(@orchestration.BoardUnavailable))
  })
}
