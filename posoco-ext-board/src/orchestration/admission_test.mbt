///|
async test "planning inspects metadata without input reservation or effects; default admission disabled" {
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
    let disabled = @orchestration.BoardOrchestrator(owner~, resolver~)
    let blocked = disabled.plan().unwrap()
    assert_eq(blocked.eligible.length(), 0)
    assert_true(
      blocked.blocked[0].reasons.contains(@orchestration.AdmissionDisabled),
    )
    assert_true(disabled.dispatch_next() is Ok(@orchestration.Blocked(_)))
    let scheduler = orch_facade(owner, resolver)
    let before = backend.state().unwrap()
    let plan = scheduler.plan().unwrap()
    assert_eq(plan.eligible, [{ task_id: "task", attempt_id: "attempt", }])
    assert_eq(scheduler.plan().unwrap(), plan)
    assert_eq(backend.state().unwrap(), before)
    assert_eq(resolver.calls, 0)
    assert_eq(journal.writes, 0)
    assert_eq(adapter.calls, 0)
    assert_true(owner.bindings().is_empty())
    plan.eligible.clear()
    assert_eq(scheduler.plan().unwrap().eligible.length(), 1)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "explicit dispatch occupies single slot and status reports real identity without prompting data" {
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
    let status = scheduler.status().unwrap()
    assert_true(status.policy_enabled)
    assert_false(status.admission_enabled)
    assert_eq(status.owner.active.unwrap().execution_id, handle.execution_id())
    assert_eq(status.owner.active.unwrap().task_id, "task")
    assert_eq(status.owner.active.unwrap().attempt_id, "attempt")
    assert_eq(status.plan.eligible.length(), 0)
    assert_true(
      status.plan.blocked[0].reasons.contains(@orchestration.ExecutionActive),
    )
    assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
    assert_eq(adapter.effects, 1)
    adapter.release.put(())
    assert_eq(handle.wait().phase, @execution.Settled)
    assert_true(scheduler.status().unwrap().owner.active is None)
    assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
    assert_eq(adapter.effects, 1)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "concurrent dispatch resolver and multiple facades cannot admit two runs" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    let adapter = orch_adapter(block=true)
    let journal = orch_journal(hold_at=1)
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    let resolver = orch_resolver(block=true)
    let scheduler = orch_facade(owner, resolver)
    let first = group.spawn(() => scheduler.dispatch_next())
    resolver.entered.get()
    assert_true(scheduler.dispatch_next() is Err(@orchestration.Busy))
    assert_true(scheduler.status().unwrap().dispatch_busy)
    assert_true(
      scheduler.plan().unwrap().blocked[0].reasons.contains(
        @orchestration.AdmissionInProgress,
      ),
    )
    resolver.release.put(())
    journal.entered.get()
    let other = orch_facade(owner, orch_resolver())
    assert_true(other.dispatch_next() is Ok(@orchestration.Blocked(_)))
    journal.release.put(())
    let handle = orch_handle(first.wait())
    adapter.entered.get()
    assert_eq(journal.writes, 3)
    assert_eq(adapter.effects, 1)
    assert_true(
      scheduler.cancel_active("wrong") is Err(@execution.WrongExecution),
    )
    assert_true(scheduler.cancel_active(handle.execution_id()) is Ok(_))
    assert_true(scheduler.cancel_active(handle.execution_id()) is Ok(_))
    assert_eq(handle.wait().outcome, Some(@execution.Cancelled))
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "stale planning revision returns updated plan without resolving input" {
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
    let old = scheduler.plan().unwrap()
    orch_command(backend, "board.task.update", { "id": "task", "title": "new" })
    match scheduler.dispatch_next(planning_revision=old.revision) {
      Ok(@orchestration.StalePlan(plan)) =>
        assert_eq(plan.revision, old.revision + 1L)
      _ => fail("stale plan must not dispatch")
    }
    assert_eq(resolver.calls, 0)
    assert_eq(journal.writes, 0)
    assert_eq(adapter.effects, 0)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "revision changes during async authorization discard resolved input without automatic retry" {
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
    orch_command(backend, "board.task.move", { "id": "task", "to": "refining" })
    resolver.release.put(())
    match dispatch.wait() {
      Ok(@orchestration.StalePlan(plan)) => {
        assert_eq(plan.eligible.length(), 0)
        assert_true(
          plan.blocked[0].reasons.contains(@orchestration.TaskStageIneligible),
        )
      }
      _ => fail("changed authoritative state must be re-planned")
    }
    assert_eq(journal.writes, 0)
    assert_eq(adapter.effects, 0)
    assert_eq(resolver.calls, 1)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "input metadata and actual authorization both fail closed; invalid identities never reserve" {
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
    resolver.hint = @orchestration.Missing
    assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
    resolver.hint = @orchestration.Denied
    assert_true(
      scheduler.plan().unwrap().blocked[0].reasons.contains(
        @orchestration.AuthorizationDenied,
      ),
    )
    assert_eq(resolver.calls, 0)
    resolver.hint = @orchestration.Available
    resolver.resolution = Some(@orchestration.NotAuthorized)
    assert_true(
      scheduler.dispatch_next() is Err(@orchestration.AuthorizationRejected),
    )
    resolver.resolution = Some(@orchestration.InputMissing)
    assert_true(
      scheduler.dispatch_next() is Err(@orchestration.InputUnavailable),
    )
    for input in ["", "valid"] {
      resolver.resolution = Some(
        @orchestration.Authorized({
          execution_id: "",
          session_id: "s",
          input,
          timeout_ms: None,
        }),
      )
      assert_true(
        scheduler.dispatch_next()
        is Err(@orchestration.OwnerRejected(@execution.InvalidRequest)),
      )
    }
    assert_eq(journal.writes, 0)
    assert_eq(adapter.calls, 0)
    adapter.available = false
    assert_true(
      scheduler.plan().unwrap().blocked[0].reasons.contains(
        @orchestration.HostUnavailable,
      ),
    )
    assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
async test "owner inspection distinguishes unattached unavailable and closed headless state" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=orch_adapter(),
      store=orch_journal(),
    )
    let scheduler = orch_facade(owner, orch_resolver())
    assert_true(
      scheduler.plan().unwrap().blocked[0].reasons.contains(
        @orchestration.OwnerNotAttached,
      ),
    )
    assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
    assert_true(owner.attach(group) is Ok(_))
    assert_true(scheduler.shutdown())
    assert_true(scheduler.dispatch_next() is Err(@orchestration.Closed))
    assert_true(
      scheduler.plan().unwrap().blocked[0].reasons.contains(
        @orchestration.OwnerClosed,
      ),
    )
    backend.shutdown()
    assert_true(scheduler.plan() is Err(@orchestration.BoardUnavailable))
  })
}

///|
async test "metadata authorization withdrawal during resolver returns stale plan without reservation" {
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
    let revision = backend.state().unwrap().revision
    let call = group.spawn(() => scheduler.dispatch_next())
    resolver.entered.get()
    resolver.hint = @orchestration.Denied
    resolver.release.put(())
    match call.wait() {
      Ok(@orchestration.StalePlan(plan)) => {
        assert_eq(plan.revision, revision)
        assert_true(
          plan.blocked[0].reasons.contains(@orchestration.AuthorizationDenied),
        )
      }
      _ => fail("authorization change must prevent reservation")
    }
    assert_eq(journal.writes, 0)
    assert_eq(adapter.calls, 0)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}
