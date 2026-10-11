///|
/// Input handling and progress visibility: the explicit ephemeral input must
/// reach the admitted execution request, while progress metadata, the
/// execution journal and the Board event stream stay ID-only.

///|
async test "progress carries identities only and input never reaches the Board" {
  @async.with_task_group(group => {
    let h = workflow_harness(
      group,
      tasks=["alpha"],
      adapter=scripted_adapter(hold=true),
    )
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    h.adapter.entered.get()
    let active = h.runner.status()
    // Detached progress: candidate identity and owned execution identity.
    assert_eq(active.current.unwrap().task_id, "alpha")
    assert_eq(active.current.unwrap().attempt_id, "attempt-alpha-1")
    assert_eq(active.execution_id, Some(h.resolver.execution_ids[0]))
    assert_eq(active.admitted, 1)
    // The explicit input reached the adapter request...
    assert_eq(h.adapter.requests.length(), 1)
    assert_true(
      h.adapter.requests[0].input.contains("explicit workflow input 1"),
    )
    assert_eq(h.adapter.requests[0].session_id, h.resolver.session_ids[0])
    // ...but the journal is identity metadata only.
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 1)
    assert_eq(bindings[0].task_id, "alpha")
    assert_eq(bindings[0].attempt_id, "attempt-alpha-1")
    assert_eq(bindings[0].execution_id, h.resolver.execution_ids[0])
    assert_eq(bindings[0].session_id, h.resolver.session_ids[0])
    // ...and no retained Board event ever carries the input payload.
    for payload in workflow_event_payloads(h.backend) {
      assert_false(payload.contains("explicit workflow input"))
    }
    h.adapter.release.put(())
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Completed))
    assert_true(status.current is None)
    // The settled stream stays payload-free, including execution telemetry.
    for payload in workflow_event_payloads(h.backend) {
      assert_false(payload.contains("explicit workflow input"))
    }
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "a missing input hint stops the run before any dispatch" {
  @async.with_task_group(group => {
    // beta has no authorized input hint: the precheck stops the run instead
    // of silently executing the available alpha.
    let h = workflow_harness(
      group,
      tasks=["alpha", "beta"],
      resolver=Some(scripted_resolver(available=["alpha/attempt-alpha-1"])),
    )
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Failed))
    assert_eq(
      status.reason,
      Some(@workflow.AdmissionRejected(@orchestration.InputUnavailable)),
    )
    assert_eq(status.admitted, 0)
    // Nothing was resolved and nothing produced effects.
    assert_eq(h.adapter.run_order, [])
    assert_eq(h.resolver.resolved_attempts, [])
    assert_true(h.owner.bindings().is_empty())
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
