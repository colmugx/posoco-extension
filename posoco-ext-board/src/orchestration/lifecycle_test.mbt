///|
async test "cancel dispatch during resolver owns no admission and no identities" {
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
    let resolver = orch_resolver(block=true)
    let scheduler = orch_facade(owner, resolver)
    let task = group.spawn(() => scheduler.dispatch_next())
    resolver.entered.get()
    task.cancel()
    assert_true(
      task.wait()
      is Err(@orchestration.DispatchCancelled(cleanup_confirmed=true)),
    )
    assert_true(owner.bindings().is_empty())
    assert_false(scheduler.status().unwrap().dispatch_busy)
    assert_eq(journal.writes, 0)
    assert_eq(adapter.calls, 0)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "cancel dispatch during protected reservation cancels and joins exact owned run" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    let adapter = orch_adapter(block=true, delay_gate=true)
    let journal = orch_journal(hold_at=1)
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    let scheduler = orch_facade(owner, orch_resolver())
    let task = group.spawn(() => scheduler.dispatch_next())
    journal.entered.get()
    task.cancel()
    journal.release.put(())
    assert_true(
      task.wait()
      is Err(@orchestration.DispatchCancelled(cleanup_confirmed=true)),
    )
    assert_true(owner.status().active is None)
    assert_eq(owner.bindings().length(), 1)
    assert_eq(owner.bindings()[0].outcome, Some(@execution.Cancelled))
    // The gated driver cannot reach Start; reserved identity remains unresolved.
    assert_eq(owner.bindings()[0].phase, @execution.Unresolved)
    assert_eq(adapter.effects, 0)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "shutdown does not release ownership while resolver admission is in flight" {
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
    let resolver = orch_resolver(block=true)
    let scheduler = orch_facade(owner, resolver)
    let dispatch = group.spawn(() => scheduler.dispatch_next())
    resolver.entered.get()
    assert_false(scheduler.shutdown())
    resolver.release.put(())
    assert_true(dispatch.wait() is Err(@orchestration.Closed))
    assert_true(scheduler.shutdown())
    assert_eq(journal.writes, 0)
    assert_eq(adapter.calls, 0)
    backend.shutdown()
  })
}

///|
async test "policy gate rechecks stage changes during reservation before provider effect" {
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
    let scheduler = orch_facade(owner, orch_resolver())
    let handle = orch_handle(scheduler.dispatch_next())
    adapter.before_gate.get()
    orch_command(backend, "board.task.move", { "id": "task", "to": "suspended" })
    adapter.gate_release.put(())
    assert_eq(handle.wait().phase, @execution.Unresolved)
    assert_eq(adapter.effects, 0)
    assert_eq(backend.state().unwrap().attempts[0].status, @domain.Queued)
    assert_true(
      scheduler.plan().unwrap().blocked[0].reasons.contains(
        @orchestration.UnresolvedExecution,
      ),
    )
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "dependency changes after admission do not implicitly cancel owned execution" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    orch_command(backend, "board.task.create", {
      "id": "dependency",
      "title": "Manual dependency",
      "description": "",
      "priority": "normal",
      "definition_of_done": [],
      "dependencies": [],
    })
    let adapter = orch_adapter(block=true)
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=orch_journal(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let scheduler = orch_facade(owner, orch_resolver())
    let handle = orch_handle(scheduler.dispatch_next())
    adapter.entered.get()
    orch_command(backend, "board.task.set_dependencies", {
      "id": "task",
      "dependencies": ["dependency"],
    })
    assert_true(owner.status().active is Some(_))
    assert_eq(backend.state().unwrap().attempts[0].status, @domain.Running)
    adapter.release.put(())
    assert_eq(handle.wait().phase, @execution.Settled)
    let state = backend.state().unwrap()
    assert_eq(state.attempts[0].status, @domain.Succeeded)
    assert_eq(state.tasks[0].stage, @domain.Ready)
    assert_eq(state.tasks[0].dependencies.map(id => id.value), ["dependency"])
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "dependency not Done blocks automation without prohibiting domain Ready" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    orch_command(backend, "board.task.create", {
      "id": "dependency",
      "title": "Manual dependency",
      "description": "",
      "priority": "normal",
      "definition_of_done": [],
      "dependencies": [],
    })
    orch_command(backend, "board.task.set_dependencies", {
      "id": "task",
      "dependencies": ["dependency"],
    })
    assert_eq(backend.state().unwrap().tasks[0].stage, @domain.Ready)
    let adapter = orch_adapter()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=orch_journal(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let scheduler = orch_facade(owner, orch_resolver())
    let plan = scheduler.plan().unwrap()
    assert_true(
      plan.blocked[0].reasons.contains(
        @orchestration.DependencyNotDone("dependency"),
      ),
    )
    assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
    for stage in ["refining", "ready", "running", "review", "done"] {
      orch_command(backend, "board.task.move", {
        "id": "dependency",
        "to": stage,
      })
    }
    assert_eq(scheduler.plan().unwrap().eligible.length(), 1)
    assert_eq(
      orch_handle(scheduler.dispatch_next()).wait().phase,
      @execution.Settled,
    )
    assert_eq(backend.state().unwrap().tasks[1].stage, @domain.Done)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "manual Finish racing execution settlement is never overwritten or retried" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    let adapter = orch_adapter(block=true)
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=orch_journal(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let scheduler = orch_facade(owner, orch_resolver())
    let handle = orch_handle(scheduler.dispatch_next())
    adapter.entered.get()
    orch_command(backend, "board.attempt.finish", {
      "id": "attempt",
      "outcome": "failed",
    })
    let revision = backend.state().unwrap().revision
    adapter.release.put(())
    assert_eq(handle.wait().phase, @execution.Unresolved)
    assert_eq(backend.state().unwrap().revision, revision)
    assert_eq(backend.state().unwrap().attempts[0].status, @domain.Failed)
    assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
    assert_eq(adapter.effects, 1)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}
