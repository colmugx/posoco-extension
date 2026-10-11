///|
struct WorkflowFaultJournal {
  mut writes : Int
  records : Array[@execution.BoardExecutionBinding]
  fail_at : Int
  visible : Bool
}

///|
impl @execution.BoardExecutionStore for WorkflowFaultJournal with fn load(self) {
  Ok(self.records.copy())
}

///|
impl @execution.BoardExecutionStore for WorkflowFaultJournal with fn persist(
  self,
  records,
) {
  self.writes += 1
  if self.writes == self.fail_at && !self.visible {
    return Err(@execution.StoreUnavailable)
  }
  self.records.clear()
  self.records.append(records)
  if self.writes == self.fail_at {
    Err(@execution.StoreUnavailable)
  } else {
    Ok(())
  }
}

///|
async test "reservation ambiguity stops without executing or replaying" {
  for visible in [false, true] {
    @async.with_task_group(group => {
      let journal : WorkflowFaultJournal = {
        writes: 0,
        records: [],
        fail_at: 1,
        visible,
      }
      let h = workflow_harness(group, tasks=["alpha"], store=journal)
      assert_true(h.runner.start(workflow_spec()) is Ok(_))
      let status = h.runner.wait()
      assert_eq(status.phase, @workflow.Unresolved)
      assert_eq(h.adapter.runs, 0)
      assert_eq(journal.writes, 1)
      assert_eq(h.owner.bindings().length(), 1)
      assert_true(
        h.runner.start(workflow_spec(run_id="fresh"))
        is Err(@workflow.UnresolvedOwner),
      )
      assert_eq(journal.writes, 1)
      assert_true(h.runner.shutdown())
      h.backend.shutdown()
    })
  }
}

///|
async test "finished or settled journal write ambiguity never admits a second run" {
  for fail_at in [4, 5] {
    @async.with_task_group(group => {
      let journal : WorkflowFaultJournal = {
        writes: 0,
        records: [],
        fail_at,
        visible: true,
      }
      let h = workflow_harness(group, tasks=["alpha", "beta"], store=journal)
      assert_true(
        h.runner.start(
          workflow_spec(failure_policy=@workflow.ContinueOnConfirmedFailure),
        )
        is Ok(_),
      )
      let status = h.runner.wait()
      assert_eq(status.phase, @workflow.Unresolved)
      assert_eq(h.adapter.runs, 1)
      assert_eq(status.succeeded, 0)
      assert_eq(journal.writes, fail_at)
      assert_eq(h.owner.bindings()[0].phase, @execution.Unresolved)
      assert_true(h.runner.shutdown())
      h.backend.shutdown()
    })
  }
}

///|
struct WorkflowFinishStore {
  inner : @store.MemoryBoardStore
  uncertain : Bool
}

///|
impl @store.BoardStore for WorkflowFinishStore with fn load(self) {
  self.inner.load()
}

///|
impl @store.BoardStore for WorkflowFinishStore with fn persist(
  self,
  snapshot,
  events,
) {
  if events.any(event => event is @domain.AttemptFinished(..)) {
    if self.uncertain {
      ignore(self.inner.persist(snapshot, events))
      return Err(@store.DurabilityUncertain("injected safe test error"))
    }
    return Err(@store.Io("injected safe test error"))
  }
  self.inner.persist(snapshot, events)
}

///|
async test "Board persistence failure and uncertainty stop even after real completion" {
  for uncertain in [false, true] {
    @async.with_task_group(group => {
      let backend = @backend.BoardBackend(
        store=WorkflowFinishStore::{
          inner: @store.MemoryBoardStore(),
          uncertain,
        },
        now_ms=() => 1234L,
      )
      backend.attach(group)
      assert_true(backend.bootstrap_snapshot() is Ok(_))
      workflow_task(backend, "alpha")
      workflow_task(backend, "beta")
      let adapter = scripted_adapter()
      let owner = @execution.BoardExecutionOwner(
        backend~,
        adapter~,
        store=@execution.MemoryBoardExecutionStore(),
      )
      assert_true(owner.attach(group) is Ok(_))
      let resolver = scripted_resolver(available=[
        "alpha/attempt-alpha-1", "beta/attempt-beta-1",
      ])
      let orchestrator = @orchestration.BoardOrchestrator(
        owner~,
        resolver~,
        policy=@orchestration.ExecutionPolicy(enabled=true),
      )
      let runner = @workflow.SequentialWorkflowRunner(orchestrator~, group~)
      assert_true(
        runner.start(
          workflow_spec(failure_policy=@workflow.ContinueOnConfirmedFailure),
        )
        is Ok(_),
      )
      let status = runner.wait()
      assert_eq(status.phase, @workflow.Unresolved)
      assert_eq(adapter.runs, 1)
      assert_eq(status.succeeded, 0)
      let binding = owner.bindings()[0]
      let snapshot = backend.state().unwrap()
      let attempt = snapshot.attempts.filter(attempt => {
          attempt.id.value == binding.attempt_id
        })[0]
      assert_eq(
        attempt.status,
        if uncertain {
          @domain.Succeeded
        } else {
          @domain.Running
        },
      )
      assert_eq(binding.phase, @execution.Unresolved)
      assert_true(runner.shutdown())
      backend.shutdown()
    })
  }
}

///|
async test "manual finish race remains authoritative and blocks further execution" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha", "beta"],
      adapter=scripted_adapter(hold=true),
    )
    assert_true(h.runner.start(workflow_spec()) is Ok(_))
    h.adapter.entered.get()
    let attempt_id = h.adapter.requests[0].attempt_id
    workflow_command(h.backend, "board.attempt.finish", {
      "id": attempt_id,
      "outcome": "failed",
    })
    h.adapter.release.put(())
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Unresolved)
    assert_eq(h.adapter.runs, 1)
    let attempt = h.backend.state().unwrap().attempts.filter(attempt => {
        attempt.id.value == attempt_id
      })[0]
    assert_eq(attempt.status, @domain.Failed)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "dependency completion affects fresh planning without implicit task changes" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha", "beta"],
      adapter=scripted_adapter(hold=true),
    )
    workflow_command(h.backend, "board.task.set_dependencies", {
      "id": "beta",
      "dependencies": ["alpha"],
    })
    assert_true(h.runner.start(workflow_spec()) is Ok(_))
    h.adapter.entered.get()
    assert_eq(h.adapter.requests[0].task_id, "alpha")
    for stage in ["running", "review", "done"] {
      workflow_command(h.backend, "board.task.move", {
        "id": "alpha",
        "to": stage,
      })
    }
    h.adapter.release.put(())
    h.adapter.entered.get()
    assert_eq(h.adapter.requests[1].task_id, "beta")
    h.adapter.release.put(())
    let status = h.runner.wait()
    assert_eq(status.succeeded, 2)
    let snapshot = h.backend.state().unwrap()
    assert_eq(
      snapshot.tasks.filter(task => task.id.value == "alpha")[0].stage,
      @domain.Done,
    )
    assert_eq(
      snapshot.tasks.filter(task => task.id.value == "beta")[0].stage,
      @domain.Ready,
    )
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "a new runner does not automatically resume and historical attempts remain spent" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha"])
    assert_true(h.runner.start(workflow_spec()) is Ok(_))
    assert_eq(h.runner.wait().succeeded, 1)
    let next = @workflow.SequentialWorkflowRunner(
      orchestrator=h.orchestrator,
      group~,
    )
    assert_eq(next.status().phase, @workflow.Idle)
    assert_eq(h.adapter.runs, 1)
    assert_true(next.start(workflow_spec(run_id="new-authorization")) is Ok(_))
    assert_eq(next.wait().admitted, 0)
    assert_eq(h.adapter.runs, 1)
    assert_true(next.shutdown())
    h.backend.shutdown()
  })
}
