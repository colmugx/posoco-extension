///|
/// Sequencing guarantees: one loop, one dispatch slot, deterministic planning
/// order, and scope exclusions. No execution ever overlaps another.

///|
async test "two tasks run strictly sequentially in deterministic planning order" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha", "beta"])
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 2)
    assert_eq(status.succeeded, 2)
    assert_eq(status.failed, 0)
    assert_eq(status.remaining_executions, 8)
    // The second dispatch started only after the first settled.
    assert_eq(h.adapter.max_active, 1)
    assert_eq(h.adapter.run_order, ["attempt-alpha-1", "attempt-beta-1"])
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 2)
    assert_eq(bindings[0].attempt_id, "attempt-alpha-1")
    assert_eq(bindings[1].attempt_id, "attempt-beta-1")
    for binding in bindings {
      assert_eq(binding.phase, @execution.Settled)
      assert_eq(binding.outcome, Some(@execution.Completed))
    }
    assert_eq(status.board_revision, Some(h.backend.state().unwrap().revision))
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "selected scope executes only the authorized tasks" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha", "beta", "gamma"])
    let previous_events = h.backend.event_history().length()
    assert_true(
      h.runner.start(
        workflow_spec(
          run_id="run-1",
          scope=@workflow.Selected(["alpha", "gamma"]),
        ),
      )
      is Ok(_),
    )
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.admitted, 2)
    assert_eq(status.succeeded, 2)
    // beta is never admitted, never resolved and never started on the Board.
    assert_eq(h.adapter.run_order, ["attempt-alpha-1", "attempt-gamma-1"])
    for binding in h.owner.bindings() {
      assert_false(binding.attempt_id == "attempt-beta-1")
    }
    assert_false(h.resolver.resolved_attempts.contains("attempt-beta-1"))
    let events = h.backend.event_history()
    for index in previous_events..<events.length() {
      assert_false(events[index].payload.stringify().contains("attempt-beta-1"))
    }
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "selected scope cannot authorize a task twice in one run" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha"])
    assert_true(
      h.runner.start(
        workflow_spec(
          run_id="run-1",
          scope=@workflow.Selected(["alpha", "alpha"]),
        ),
      )
      is Ok(_),
    )
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    // Duplicated selection collapses to one authorized execution.
    assert_eq(status.admitted, 1)
    assert_eq(status.succeeded, 1)
    assert_eq(h.adapter.runs, 1)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
