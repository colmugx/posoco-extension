///|
/// SequentialWorkflowRunner lifecycle: explicit authorization, duplicate
/// identity, pause/resume, stop-after-current, cancel and shutdown. Every
/// await is a queue handoff or a cooperative yield; no wall-clock timing.

///|
async test "start completes one admitted execution and reports detached progress" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha"])
    let idle = h.runner.status()
    assert_true(workflow_phase_eq(idle.phase, @workflow.Idle))
    assert_true(idle.run_id is None)
    assert_eq(idle.admitted, 0)
    assert_eq(idle.remaining_executions, 0)
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    let running = h.runner.status()
    assert_true(workflow_phase_eq(running.phase, @workflow.Running))
    assert_eq(running.run_id, Some("run-1"))
    assert_eq(running.remaining_executions, 10)
    assert_eq(running.elapsed_ms, 0L)
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.run_id, Some("run-1"))
    assert_eq(status.admitted, 1)
    assert_eq(status.succeeded, 1)
    assert_eq(status.failed, 0)
    assert_eq(status.cancelled, 0)
    assert_eq(status.remaining_executions, 9)
    assert_true(status.current is None)
    assert_true(h.runner.status().execution_id is None)
    assert_eq(status.board_revision, Some(h.backend.state().unwrap().revision))
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 1)
    assert_eq(bindings[0].task_id, "alpha")
    assert_eq(bindings[0].attempt_id, "attempt-alpha-1")
    assert_eq(bindings[0].phase, @execution.Settled)
    assert_eq(bindings[0].outcome, Some(@execution.Completed))
    assert_eq(h.adapter.max_active, 1)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "start rejects concurrent runs and a reused run identity" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha"],
      adapter=scripted_adapter(hold=true),
    )
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    workflow_yield_until(what="first run", check=() => h.adapter.runs == 1)
    // A second authorization may not run while one loop owns the runner.
    assert_true(
      h.runner.start(workflow_spec(run_id="run-2"))
      is Err(@workflow.AlreadyRunning),
    )
    h.adapter.release.put(())
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.succeeded, 1)
    // The consumed run identity is rejected without touching state.
    assert_true(
      h.runner.start(workflow_spec(run_id="run-1"))
      is Err(@workflow.DuplicateRunIdentity),
    )
    assert_eq(h.adapter.runs, 1)
    assert_eq(status.run_id, Some("run-1"))
    // New explicit authorization restarts; there is no eligible work left.
    assert_true(h.runner.start(workflow_spec(run_id="run-2")) is Ok(_))
    let second = h.runner.wait()
    assert_true(workflow_phase_eq(second.phase, @workflow.Completed))
    assert_eq(second.run_id, Some("run-2"))
    assert_eq(second.admitted, 0)
    assert_eq(h.adapter.runs, 1)
    assert_eq(h.resolver.execution_ids.length(), 1)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "pause before the first dispatch admits nothing until resume" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha"])
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    assert_true(h.runner.pause())
    workflow_wait_phase(h, @workflow.Paused)
    assert_eq(h.adapter.runs, 0)
    let paused = h.runner.status()
    assert_eq(paused.admitted, 0)
    assert_true(paused.current is None)
    assert_true(paused.execution_id is None)
    // Pausing a paused runner is not a new request.
    assert_false(h.runner.pause())
    assert_true(h.runner.resume_workflow())
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_eq(status.succeeded, 1)
    assert_eq(h.adapter.runs, 1)
    // Controls on a finished run are refused.
    assert_false(h.runner.pause())
    assert_false(h.runner.resume_workflow())
    assert_false(h.runner.stop_after_current())
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "pause during an active execution lets it settle before pausing" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha", "beta"],
      adapter=scripted_adapter(hold=true),
    )
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    h.adapter.entered.get()
    assert_true(h.runner.pause())
    let pausing = h.runner.status()
    assert_true(workflow_phase_eq(pausing.phase, @workflow.Pausing))
    assert_eq(pausing.current.unwrap().task_id, "alpha")
    assert_eq(pausing.current.unwrap().attempt_id, "attempt-alpha-1")
    assert_eq(pausing.execution_id, Some(h.resolver.execution_ids[0]))
    h.adapter.release.put(())
    workflow_wait_phase(h, @workflow.Paused)
    let paused = h.runner.status()
    assert_eq(paused.admitted, 1)
    assert_eq(paused.succeeded, 1)
    assert_eq(paused.remaining_executions, 9)
    assert_eq(h.adapter.runs, 1)
    assert_true(h.runner.resume_workflow())
    h.adapter.entered.get()
    h.adapter.release.put(())
    let done = h.runner.wait()
    assert_true(workflow_phase_eq(done.phase, @workflow.Completed))
    assert_eq(done.succeeded, 2)
    assert_eq(h.adapter.max_active, 1)
    assert_eq(h.adapter.run_order, ["attempt-alpha-1", "attempt-beta-1"])
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "stop after current finishes the admitted run and skips the rest" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha", "beta"],
      adapter=scripted_adapter(hold=true),
    )
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    h.adapter.entered.get()
    assert_true(h.runner.stop_after_current())
    assert_true(workflow_phase_eq(h.runner.status().phase, @workflow.Stopping))
    h.adapter.release.put(())
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Stopped))
    assert_eq(status.reason, Some(@workflow.StopRequested))
    assert_eq(status.admitted, 1)
    assert_eq(status.succeeded, 1)
    assert_eq(h.adapter.runs, 1)
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 1)
    assert_eq(bindings[0].attempt_id, "attempt-alpha-1")
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "stop from paused ends the run without admissions" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha"])
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    assert_true(h.runner.pause())
    workflow_wait_phase(h, @workflow.Paused)
    assert_true(h.runner.stop_after_current())
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Stopped))
    assert_eq(status.reason, Some(@workflow.StopRequested))
    assert_eq(status.admitted, 0)
    assert_true(h.owner.bindings().is_empty())
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "cancel from paused prevents any admission" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha"])
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    assert_true(h.runner.pause())
    workflow_wait_phase(h, @workflow.Paused)
    h.runner.cancel()
    workflow_wait_phase(h, @workflow.Stopped)
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Stopped))
    assert_eq(status.reason, Some(@workflow.CancelRequested))
    assert_eq(status.admitted, 0)
    assert_true(h.owner.bindings().is_empty())
    // Cancelling a finished run is a no-op.
    h.runner.cancel()
    assert_true(workflow_phase_eq(h.runner.status().phase, @workflow.Stopped))
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "cancel during an active execution settles it as cancelled" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha"],
      adapter=scripted_adapter(hold=true),
    )
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    h.adapter.entered.get()
    h.runner.cancel()
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Stopped))
    assert_eq(status.succeeded, 0)
    assert_eq(status.admitted, 1)
    assert_true(status.current is None)
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 1)
    assert_eq(bindings[0].phase, @execution.Settled)
    assert_eq(bindings[0].outcome, Some(@execution.Cancelled))
    assert_eq(h.adapter.runs, 1)
    assert_eq(h.adapter.max_active, 1)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "shutdown during an active run cancels joins and closes admission" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha"],
      adapter=scripted_adapter(hold=true),
    )
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    h.adapter.entered.get()
    assert_true(h.runner.shutdown(timeout_ms=4000))
    let status = h.runner.status()
    assert_true(workflow_phase_eq(status.phase, @workflow.Stopped))
    assert_eq(status.succeeded, 0)
    assert_eq(status.admitted, 1)
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 1)
    assert_eq(bindings[0].outcome, Some(@execution.Cancelled))
    assert_true(
      h.runner.start(workflow_spec(run_id="run-2")) is Err(@workflow.Closed),
    )
    // Repeated shutdown stays confirmed and idempotent.
    assert_true(h.runner.shutdown())
    assert_true(h.orchestrator.shutdown())
    h.backend.shutdown()
  })
}
