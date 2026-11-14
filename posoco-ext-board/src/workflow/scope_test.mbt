///|
/// Scope integrity: the selection is copied at start, the eligible-at-start
/// snapshot freezes at start, manual Board mutation changes eligibility
/// explicitly, new Attempts on scoped tasks are fresh admissions, and spent
/// Attempts never replay.

///|
async test "the runner copies the selected scope and never mutates caller state" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha", "beta"])
    let selection = ["alpha"]
    assert_true(
      h.runner.start(
        workflow_spec(run_id="run-1", scope=@workflow.Selected(selection)),
      )
      is Ok(_),
    )
    // Caller-side mutation after start cannot widen the frozen scope.
    selection.push("beta")
    selection.push("alpha")
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.succeeded, 1)
    assert_eq(h.adapter.run_order, ["attempt-alpha-1"])
    // The runner also never reordered, deduplicated or cleared the caller's
    // array: the scope it used was a copy.
    assert_eq(selection, ["alpha", "beta", "alpha"])
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "manual mutation while paused removes eligibility without cancelling" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha"])
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    assert_true(h.runner.pause())
    workflow_wait_phase(h, @workflow.Paused)
    // A human moves the only scoped task out of Ready while paused.
    workflow_command(h.backend, "board.task.move", {
      "id": "alpha",
      "to": "suspended",
    })
    assert_true(h.runner.resume_workflow())
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 0)
    assert_true(h.owner.bindings().is_empty())
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "tasks created after start stay outside the frozen scope" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha"],
      adapter=scripted_adapter(hold=true),
    )
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    h.adapter.entered.get()
    // A new fully eligible task appears while the run is active.
    workflow_task(h.backend, "zeta")
    h.adapter.release.put(())
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.succeeded, 1)
    // zeta was eligible on the Board but was never authorized by this run.
    assert_eq(h.adapter.run_order, ["attempt-alpha-1"])
    assert_false(h.resolver.resolved_attempts.contains("attempt-zeta-1"))
    for binding in h.owner.bindings() {
      assert_false(binding.task_id == "zeta")
    }
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "new attempts on a scoped task are fresh admissions and spent attempts never replay" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha"],
      adapter=scripted_adapter(hold=true),
    )
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    h.adapter.entered.get()
    // A human queues a second Attempt while the first is active and the host
    // authorizes its input for future admissions.
    workflow_command(h.backend, "board.attempt.queue", {
      "id": "attempt-alpha-2",
      "task_id": "alpha",
      "kind": "execute",
    })
    h.resolver.available.push("alpha/attempt-alpha-2")
    h.adapter.release.put(())
    h.adapter.entered.get()
    h.adapter.release.put(())
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 2)
    assert_eq(status.succeeded, 2)
    // Each Attempt ran exactly once with fresh identity; the settled first
    // Attempt was never replayed.
    assert_eq(h.adapter.run_order, ["attempt-alpha-1", "attempt-alpha-2"])
    assert_eq(h.resolver.execution_ids.length(), 2)
    assert_false(h.resolver.execution_ids[0] == h.resolver.execution_ids[1])
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 2)
    assert_eq(bindings[0].attempt_id, "attempt-alpha-1")
    assert_eq(bindings[1].attempt_id, "attempt-alpha-2")
    for binding in bindings {
      assert_eq(binding.phase, @execution.Settled)
      assert_eq(binding.outcome, Some(@execution.Completed))
    }
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
