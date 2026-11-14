///|
/// Budgets: structural validation of the wave specification including the
/// concurrency ceiling, constructor defaults with detached scope copies, the
/// consumed run identity, and an elapsed budget that keeps running while
/// paused.

///|
test "the wave spec constructor defaults to one slot and stop on failure" {
  let ids = ["alpha"]
  let spec = @parallel.ParallelWorkflowSpec(
    run_id="host-wave",
    scope=@workflow.Selected(ids),
    max_executions=2,
    max_elapsed_ms=10000,
    execution_timeout_ms=1000,
  )
  ids.push("beta")
  assert_eq(spec.scope, @workflow.Selected(["alpha"]))
  assert_eq(spec.max_concurrency, 1)
  assert_eq(spec.failure_policy, @parallel.StopOnFailure)
  assert_true(spec.validate())
  let cancelling = @parallel.ParallelWorkflowSpec(
    run_id="cancelling-wave",
    scope=@workflow.AllEligibleAtStart,
    max_executions=2,
    max_elapsed_ms=10000,
    execution_timeout_ms=1000,
    max_concurrency=3,
    failure_policy=@parallel.CancelRemainingOnFailure,
  )
  assert_eq(cancelling.max_concurrency, 3)
  assert_eq(cancelling.failure_policy, @parallel.CancelRemainingOnFailure)
  assert_true(cancelling.validate())
}

///|
async test "structurally invalid waves are rejected without reserving the runner" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["alpha"], capacity=2)
    let invalid : Array[@parallel.ParallelWorkflowSpec] = [
      parallel_spec(run_id=""),
      parallel_spec(run_id="   "),
      parallel_spec(run_id="x", max_executions=0),
      parallel_spec(run_id="x", max_executions=-3),
      parallel_spec(run_id="x", max_executions=1001),
      parallel_spec(run_id="x", max_elapsed_ms=0),
      parallel_spec(run_id="x", max_elapsed_ms=-1),
      parallel_spec(run_id="x", max_elapsed_ms=86400001),
      parallel_spec(run_id="x", execution_timeout_ms=0),
      parallel_spec(run_id="x", max_elapsed_ms=100, execution_timeout_ms=101),
      parallel_spec(run_id="x", scope=@workflow.Selected([])),
      parallel_spec(run_id="x", scope=@workflow.Selected(["alpha", " "])),
      parallel_spec(run_id="x", scope=@workflow.Selected([""])),
      parallel_spec(run_id="x", max_concurrency=0),
      parallel_spec(run_id="x", max_concurrency=9),
      parallel_spec(run_id="x", max_concurrency=3),
    ]
    for spec in invalid {
      assert_true(h.runner.start(spec) is Err(@workflow.InvalidSpec))
    }
    assert_true(
      h.runner.start(
        parallel_spec(run_id="x", scope=@workflow.Selected(["missing"])),
      )
      is Err(@workflow.InvalidScope),
    )
    // Nothing leaked: no identity history, no admissions, still startable.
    assert_eq(h.shared.runs, 0)
    assert_eq(h.resolver.execution_ids.length(), 0)
    assert_true(h.owner.bindings().is_empty())
    assert_true(h.runner.start(parallel_spec(run_id="run-1")) is Ok(_))
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.succeeded, 1)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "a paused wave still consumes its elapsed budget" {
  @async.with_task_group(group => {
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta"],
      capacity=2,
      clock=parallel_clock(now=1000L),
    )
    let idle = h.runner.status()
    assert_eq(idle.run_id, None)
    assert_eq(idle.phase, @workflow.Idle)
    assert_true(
      h.runner.start(
        parallel_spec(
          run_id="run-1",
          max_elapsed_ms=1000,
          execution_timeout_ms=100,
          max_concurrency=2,
        ),
      )
      is Ok(_),
    )
    assert_eq(h.runner.status().elapsed_ms, 0L)
    assert_eq(h.runner.status().remaining_ms, 1000L)
    assert_true(h.runner.pause())
    parallel_wait_phase(h, @workflow.Paused)
    // Pausing does not stop the clock: 950ms elapsed leaves no room for a
    // 100ms execution timeout.
    h.clock.now_ms = 1950L
    let paused = h.runner.status()
    assert_eq(paused.elapsed_ms, 950L)
    assert_eq(paused.remaining_ms, 50L)
    assert_true(h.runner.resume_workflow())
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.reason, Some(@workflow.InsufficientTime))
    assert_eq(status.admitted, 0)
    assert_eq(status.remaining_ms, 50L)
    assert_true(h.owner.bindings().is_empty())
    assert_eq(h.shared.runs, 0)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
