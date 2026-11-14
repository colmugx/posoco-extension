///|
/// Budget boundaries: structural spec validation, scope resolution, the
/// execution-count budget and the elapsed-time budget, including while the
/// runner is paused. Time budgets use the injected clock, except one test
/// that deliberately holds a real structured deadline.

///|
test "spec constructor defaults to stop on failure and detaches selected scope" {
  let ids = ["alpha"]
  let spec = @workflow.WorkflowRunSpec(
    run_id="explicit-run",
    scope=@workflow.Selected(ids),
    max_executions=2,
    max_elapsed_ms=10000,
    execution_timeout_ms=1000,
  )
  ids.push("beta")
  assert_eq(spec.scope, @workflow.Selected(["alpha"]))
  assert_eq(spec.failure_policy, @workflow.StopOnFailure)
  assert_true(spec.validate())
  let continuing = @workflow.WorkflowRunSpec(
    run_id="continuing-run",
    scope=@workflow.AllEligibleAtStart,
    max_executions=2,
    max_elapsed_ms=10000,
    execution_timeout_ms=1000,
    failure_policy=@workflow.ContinueOnConfirmedFailure,
  )
  assert_eq(continuing.failure_policy, @workflow.ContinueOnConfirmedFailure)
}

///|
async test "structurally invalid specs are rejected without reserving the runner" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha"])
    let invalid : Array[@workflow.WorkflowRunSpec] = [
      workflow_spec(run_id=""),
      workflow_spec(run_id="   "),
      workflow_spec(run_id="x", max_executions=0),
      workflow_spec(run_id="x", max_executions=-3),
      workflow_spec(run_id="x", max_executions=1001),
      workflow_spec(run_id="x", max_elapsed_ms=0),
      workflow_spec(run_id="x", max_elapsed_ms=-1),
      workflow_spec(run_id="x", max_elapsed_ms=86400001),
      workflow_spec(run_id="x", execution_timeout_ms=0),
      workflow_spec(run_id="x", max_elapsed_ms=100, execution_timeout_ms=101),
      workflow_spec(run_id="x", scope=@workflow.Selected([])),
      workflow_spec(run_id="x", scope=@workflow.Selected(["alpha", " "])),
      workflow_spec(run_id="x", scope=@workflow.Selected([""])),
    ]
    for spec in invalid {
      assert_true(h.runner.start(spec) is Err(@workflow.InvalidSpec))
    }
    // Nothing leaked: no identity history, no admissions, still startable.
    assert_eq(h.adapter.runs, 0)
    assert_true(h.owner.bindings().is_empty())
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.succeeded, 1)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "a selection naming an unknown task is rejected as out of scope" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha"])
    assert_true(
      h.runner.start(
        workflow_spec(run_id="run-1", scope=@workflow.Selected(["missing"])),
      )
      is Err(@workflow.InvalidScope),
    )
    assert_eq(h.adapter.runs, 0)
    assert_true(h.owner.bindings().is_empty())
    assert_eq(h.resolver.execution_ids.length(), 0)
    // A corrected selection starts normally.
    assert_true(
      h.runner.start(
        workflow_spec(run_id="run-2", scope=@workflow.Selected(["alpha"])),
      )
      is Ok(_),
    )
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.succeeded, 1)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "the execution budget stops the loop once spent" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha", "beta"])
    assert_true(
      h.runner.start(workflow_spec(run_id="run-1", max_executions=1)) is Ok(_),
    )
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.reason, Some(@workflow.ExecutionBudgetReached))
    assert_eq(status.admitted, 1)
    assert_eq(status.succeeded, 1)
    assert_eq(status.remaining_executions, 0)
    assert_eq(h.adapter.run_order, ["attempt-alpha-1"])
    assert_eq(h.owner.bindings().length(), 1)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "a paused run still consumes its elapsed budget" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha"],
      clock=fake_clock(now=1000L),
    )
    assert_true(
      h.runner.start(
        workflow_spec(
          run_id="run-1",
          max_elapsed_ms=1000,
          execution_timeout_ms=100,
        ),
      )
      is Ok(_),
    )
    assert_eq(h.runner.status().elapsed_ms, 0L)
    assert_eq(h.runner.status().remaining_ms, 1000L)
    assert_true(h.runner.pause())
    workflow_wait_phase(h, @workflow.Paused)
    // Pausing does not stop the clock: 950ms elapsed leaves no room for a
    // 100ms execution timeout.
    h.clock.now_ms = 1950L
    let paused = h.runner.status()
    assert_eq(paused.elapsed_ms, 950L)
    assert_eq(paused.remaining_ms, 50L)
    assert_true(h.runner.resume_workflow())
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.reason, Some(@workflow.InsufficientTime))
    assert_eq(status.admitted, 0)
    assert_eq(status.remaining_ms, 50L)
    assert_true(h.owner.bindings().is_empty())
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "the structured deadline stops a held run as DeadlineReached" {
  @async.with_task_group(group => {
    // The stopped wall clock permits admission after delayed resolution. The
    // independent workflow timer must still beat the later Agent timeout.
    let h = workflow_harness(
      group,
      tasks=["alpha"],
      adapter=scripted_adapter(hold=true),
      clock=fake_clock(now=0L),
    )
    // The resolver hold delays admission; the per-execution timeout only
    // starts once admitted, so the earlier-starting workflow deadline wins.
    h.resolver.delay_ms = 100
    assert_true(
      h.runner.start(
        workflow_spec(
          run_id="run-1",
          max_elapsed_ms=400,
          execution_timeout_ms=400,
        ),
      )
      is Ok(_),
    )
    h.adapter.entered.get()
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Stopped))
    assert_eq(status.reason, Some(@workflow.DeadlineReached))
    assert_eq(status.admitted, 1)
    assert_eq(status.cancelled, 1)
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 1)
    assert_eq(bindings[0].outcome, Some(@execution.Cancelled))
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
