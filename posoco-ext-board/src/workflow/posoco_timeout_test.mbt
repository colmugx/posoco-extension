///|
async test "real model timeout is confirmed settlement, not a workflow deadline" {
  @async.with_task_group(group => {
    let model = workflow_real_model(hold=true)
    let resolver = scripted_resolver(available=["alpha/attempt-alpha-1"])
    let h = workflow_real_harness(group, tasks=["alpha"], model~, resolver~)
    assert_true(
      h.runner.start(
        workflow_spec(max_elapsed_ms=5000, execution_timeout_ms=100),
      )
      is Ok(_),
    )
    model.entered.get()
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Failed)
    assert_eq(
      status.reason,
      Some(@workflow.ExecutionFailed(@execution.TimedOut)),
    )
    assert_eq(status.failed, 1)
    assert_eq(model.calls, 1)
    assert_eq(model.stopped, 1)
    assert_eq(h.owner.bindings()[0].phase, @execution.Settled)
    assert_eq(h.owner.bindings()[0].outcome, Some(@execution.TimedOut))
    assert_eq(
      h.backend.state().unwrap().attempts[0].status,
      @domain.Interrupted,
    )
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
