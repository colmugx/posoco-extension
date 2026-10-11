///|
async test "journal failure at every reservation and settlement boundary blocks further dispatch without replay" {
  for visible_failure in [false, true] {
    for fail_at in [1, 2, 3, 4, 5] {
      @async.with_task_group(group => {
        let backend = orch_board(group)
        let adapter = orch_adapter()
        let journal = orch_journal(fail_at~, visible_failure~)
        let owner = @execution.BoardExecutionOwner(
          backend~,
          adapter~,
          store=journal,
        )
        assert_true(owner.attach(group) is Ok(_))
        let scheduler = orch_facade(owner, orch_resolver())
        let result = scheduler.dispatch_next()
        if fail_at == 1 {
          assert_true(
            result
            is Err(@orchestration.OwnerRejected(@execution.StoreUnavailable)),
          )
        } else {
          assert_eq(orch_handle(result).wait().phase, @execution.Unresolved)
        }
        assert_eq(adapter.effects, if fail_at <= 3 { 0 } else { 1 })
        assert_eq(journal.writes, fail_at)
        let status = scheduler.status().unwrap()
        assert_true(status.owner.unresolved)
        assert_true(status.policy_enabled)
        assert_false(status.admission_enabled)
        assert_eq(status.plan.eligible.length(), 0)
        assert_true(
          status.plan.blocked[0].reasons.contains(
            @orchestration.UnresolvedExecution,
          ),
        )
        assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
        assert_eq(journal.writes, fail_at)
        assert_true(scheduler.shutdown())
        backend.shutdown()
      })
    }
  }
}

///|
async test "recovered nonsettled bindings block planner admission without automatic replay or ID replacement" {
  for
    phase in [
      @execution.Reserved,
      @execution.Running,
      @execution.Finished,
      @execution.Unresolved,
    ] {
    @async.with_task_group(group => {
      let backend = orch_board(group)
      let adapter = orch_adapter()
      let journal = orch_journal()
      journal.records.push({
        task_id: "task",
        attempt_id: "attempt",
        execution_id: "old-exec",
        session_id: "old-session",
        run: if phase is @execution.Reserved {
          None
        } else {
          Some({
            session_id: "old-session",
            run_id: "old-run",
            turn_id: "old-turn",
          })
        },
        phase,
        outcome: if phase is (@execution.Finished | @execution.Unresolved) {
          Some(@execution.Completed)
        } else {
          None
        },
      })
      let owner = @execution.BoardExecutionOwner(
        backend~,
        adapter~,
        store=journal,
      )
      assert_true(owner.attach(group) is Ok(_))
      let resolver = orch_resolver()
      let scheduler = orch_facade(owner, resolver)
      assert_true(scheduler.status().unwrap().owner.unresolved)
      assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
      assert_eq(resolver.calls, 0)
      assert_eq(journal.writes, 0)
      assert_eq(adapter.calls, 0)
      assert_eq(owner.bindings()[0].execution_id, "old-exec")
      assert_true(scheduler.shutdown())
      backend.shutdown()
    })
  }
}

///|
async test "historically settled Attempt and session execution identities cannot be reused" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    let adapter = orch_adapter()
    let journal = orch_journal()
    journal.records.push({
      task_id: "task",
      attempt_id: "attempt",
      execution_id: "old-exec",
      session_id: "old-session",
      run: Some({
        session_id: "old-session",
        run_id: "old-run",
        turn_id: "old-turn",
      }),
      phase: @execution.Settled,
      outcome: Some(@execution.Completed),
    })
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    let resolver = orch_resolver()
    let scheduler = orch_facade(owner, resolver)
    assert_false(scheduler.status().unwrap().owner.unresolved)
    assert_true(
      scheduler.plan().unwrap().blocked[0].reasons.contains(
        @orchestration.IdentityAlreadyUsed,
      ),
    )
    assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
    // Add a fresh Attempt, while retaining all identity history.
    orch_command(backend, "board.attempt.start", { "id": "attempt" })
    orch_command(backend, "board.attempt.finish", {
      "id": "attempt",
      "outcome": "succeeded",
    })
    orch_command(backend, "board.attempt.queue", {
      "id": "new-attempt",
      "task_id": "task",
      "kind": "execute",
    })
    resolver.resolution = Some(
      @orchestration.Authorized({
        execution_id: "old-exec",
        session_id: "new-session",
        input: "explicit",
        timeout_ms: None,
      }),
    )
    assert_true(
      scheduler.dispatch_next()
      is Err(@orchestration.OwnerRejected(@execution.DuplicateIdentity)),
    )
    resolver.resolution = Some(
      @orchestration.Authorized({
        execution_id: "new-exec",
        session_id: "old-session",
        input: "explicit",
        timeout_ms: None,
      }),
    )
    assert_true(
      scheduler.dispatch_next()
      is Err(@orchestration.OwnerRejected(@execution.DuplicateIdentity)),
    )
    assert_eq(journal.writes, 0)
    assert_eq(adapter.calls, 0)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}

///|
struct OrchFailingBoardStore {
  inner : @store.MemoryBoardStore
  mut fail : Bool
  uncertain : Bool
  mut failures : Int
}

///|
impl @store.BoardStore for OrchFailingBoardStore with fn load(self) {
  self.inner.load()
}

///|
impl @store.BoardStore for OrchFailingBoardStore with fn persist(
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
async test "Board Finish persistence failures preserve authoritative commits and never redispatch uncertain work" {
  for uncertain in [false, true] {
    @async.with_task_group(group => {
      let storage : OrchFailingBoardStore = {
        inner: @store.MemoryBoardStore(),
        fail: false,
        uncertain,
        failures: 0,
      }
      let backend = orch_board(group, store=storage)
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
      let before = backend.state().unwrap().revision
      storage.fail = true
      adapter.release.put(())
      assert_eq(handle.wait().phase, @execution.Unresolved)
      assert_eq(storage.failures, 1)
      assert_eq(
        backend.state().unwrap().revision,
        before + (if uncertain { 1L } else { 0L }),
      )
      assert_eq(
        backend.state().unwrap().attempts[0].status,
        if uncertain {
          @domain.Succeeded
        } else {
          @domain.Running
        },
      )
      assert_eq(
        backend
        .event_history()
        .filter(event => event.kind == "board.attempt.finished")
        .length(),
        if uncertain {
          1
        } else {
          0
        },
      )
      assert_true(scheduler.status().unwrap().owner.unresolved)
      assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
      assert_eq(storage.failures, 1)
      assert_eq(adapter.effects, 1)
      assert_true(scheduler.shutdown())
      backend.shutdown()
    })
  }
}

///|
async test "unconfirmed Board Start fails closed even if the authoritative mutation committed" {
  for uncertain in [false, true] {
    @async.with_task_group(group => {
      let storage : OrchFailingBoardStore = {
        inner: @store.MemoryBoardStore(),
        fail: false,
        uncertain,
        failures: 0,
      }
      let backend = orch_board(group, store=storage)
      let adapter = orch_adapter()
      let owner = @execution.BoardExecutionOwner(
        backend~,
        adapter~,
        store=orch_journal(),
      )
      assert_true(owner.attach(group) is Ok(_))
      let scheduler = orch_facade(owner, orch_resolver())
      let revision = backend.state().unwrap().revision
      storage.fail = true
      assert_eq(
        orch_handle(scheduler.dispatch_next()).wait().phase,
        @execution.Unresolved,
      )
      assert_eq(adapter.effects, 0)
      assert_eq(storage.failures, 1)
      assert_eq(
        backend.state().unwrap().revision,
        revision + (if uncertain { 1L } else { 0L }),
      )
      assert_eq(
        backend.state().unwrap().attempts[0].status,
        if uncertain {
          @domain.Running
        } else {
          @domain.Queued
        },
      )
      assert_eq(
        backend
        .event_history()
        .filter(event => event.kind == "board.attempt.started")
        .length(),
        if uncertain {
          1
        } else {
          0
        },
      )
      assert_true(scheduler.dispatch_next() is Ok(@orchestration.Blocked(_)))
      assert_eq(storage.failures, 1)
      assert_true(scheduler.shutdown())
      backend.shutdown()
    })
  }
}
