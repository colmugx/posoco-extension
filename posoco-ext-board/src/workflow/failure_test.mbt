///|
/// Failure and uncertainty handling: the failure policy decision, unconfirmed
/// settlement, the unresolved-owner gate, and stale-plan tolerance with its
/// bounded limit. All stale plans here are produced deterministically by a
/// resolver that mutates the Board before authorization.

///|
async test "a failed execution stops the run under StopOnFailure" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha", "beta"],
      adapter=scripted_adapter(failures=1),
    )
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Failed))
    assert_eq(status.reason, Some(@workflow.ExecutionFailed(@execution.Failed)))
    assert_eq(status.admitted, 1)
    assert_eq(status.failed, 1)
    assert_eq(status.succeeded, 0)
    // beta is never admitted after the confirmed failure.
    assert_eq(h.adapter.run_order, ["attempt-alpha-1"])
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 1)
    assert_eq(bindings[0].phase, @execution.Settled)
    assert_eq(bindings[0].outcome, Some(@execution.Failed))
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "confirmed failures continue under ContinueOnConfirmedFailure" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha", "beta"],
      adapter=scripted_adapter(failures=1),
    )
    assert_true(
      h.runner.start(
        workflow_spec(
          run_id="run-1",
          failure_policy=@workflow.ContinueOnConfirmedFailure,
        ),
      )
      is Ok(_),
    )
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 2)
    assert_eq(status.failed, 1)
    assert_eq(status.succeeded, 1)
    assert_eq(h.adapter.run_order, ["attempt-alpha-1", "attempt-beta-1"])
    let bindings = h.owner.bindings()
    assert_eq(bindings[0].outcome, Some(@execution.Failed))
    assert_eq(bindings[1].outcome, Some(@execution.Completed))
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "an execution that never passes the Start gate stays unresolved" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha"],
      adapter=scripted_adapter(call_gate=false, outcome=@execution.Interrupted),
    )
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Unresolved))
    assert_eq(status.reason, Some(@workflow.UnconfirmedSettlement))
    assert_eq(h.adapter.runs, 1)
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 1)
    assert_eq(bindings[0].phase, @execution.Unresolved)
    assert_eq(bindings[0].outcome, Some(@execution.Interrupted))
    // An unresolved loop keeps ownership: restart needs a resolved owner.
    assert_true(
      h.runner.start(workflow_spec(run_id="run-2"))
      is Err(@workflow.UnresolvedOwner),
    )
    assert_eq(h.adapter.runs, 1)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "one stale plan is recomputed without replaying discarded input" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha"])
    h.resolver.stale_backend = Some(h.backend)
    h.resolver.stale_left = 1
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.succeeded, 1)
    // The first dispatch went stale after resolution; its authorization and
    // identities were discarded, not journalled or silently replayed.
    assert_eq(h.resolver.execution_ids.length(), 2)
    assert_false(h.resolver.execution_ids[0] == h.resolver.execution_ids[1])
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 1)
    assert_eq(bindings[0].execution_id, h.resolver.execution_ids[1])
    assert_eq(bindings[0].session_id, h.resolver.session_ids[1])
    assert_eq(h.adapter.runs, 1)
    // The task created by the stale mutation is not in the frozen scope and
    // never runs, even though the run continued.
    for binding in bindings {
      assert_false(binding.task_id == "stale-task-1")
    }
    assert_eq(status.board_revision, Some(h.backend.state().unwrap().revision))
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "repeated stale plans fail the run instead of spinning" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha"])
    h.resolver.stale_backend = Some(h.backend)
    h.resolver.stale_left = 99
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Failed))
    assert_eq(status.reason, Some(@workflow.StalePlanLimit))
    assert_eq(status.admitted, 0)
    assert_eq(h.adapter.runs, 0)
    assert_true(h.owner.bindings().is_empty())
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
