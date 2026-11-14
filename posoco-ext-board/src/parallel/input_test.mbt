///|
/// Input authorization and progress visibility: denied or missing input stops
/// the whole wave without silent fallback, and status stays detached
/// identity-only metadata that never leaks input or dispatches work.

///|
async test "a denied input stops the wave without falling back to another task" {
  @async.with_task_group(group => {
    let resolver = parallel_resolver(available=["alpha/attempt-alpha-1"])
    resolver.denied.push("beta/attempt-beta-1")
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta"],
      capacity=2,
      resolver=Some(resolver),
    )
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Failed)
    assert_eq(
      status.reason,
      Some(@workflow.AdmissionRejected(@orchestration.AuthorizationRejected)),
    )
    // No fallback substitution: not even the available alpha ran.
    assert_eq(status.admitted, 0)
    assert_eq(h.shared.runs, 0)
    assert_true(h.owner.bindings().is_empty())
    assert_eq(h.resolver.execution_ids.length(), 0)
    // The loop still observed the Board before stopping.
    assert_eq(status.board_revision, Some(h.backend.state().unwrap().revision))
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "a missing input stops the wave before any dispatch" {
  @async.with_task_group(group => {
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta"],
      capacity=2,
      resolver=Some(parallel_resolver(available=["alpha/attempt-alpha-1"])),
    )
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Failed)
    assert_eq(
      status.reason,
      Some(@workflow.AdmissionRejected(@orchestration.InputUnavailable)),
    )
    assert_eq(status.admitted, 0)
    assert_eq(h.shared.runs, 0)
    assert_true(h.owner.bindings().is_empty())
    assert_eq(h.resolver.execution_ids.length(), 0)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "status stays detached identity-only metadata that never dispatches" {
  @async.with_task_group(group => {
    // The trusted host also knows delta's input metadata, so delta's Review
    // stage is its only reason to stay blocked instead of failing the wave.
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta"],
      capacity=2,
      resolver=Some(
        parallel_resolver(available=[
          "alpha/attempt-alpha-1", "beta/attempt-beta-1", "delta/attempt-delta-1",
        ]),
      ),
      hold=["attempt-alpha-1", "attempt-beta-1"],
    )
    // delta parked in Review gives status one structured blocked row.
    parallel_task(h.backend, "delta")
    for stage in ["running", "review"] {
      parallel_command(h.backend, "board.task.move", {
        "id": "delta",
        "to": stage,
      })
    }
    let idle = h.runner.status()
    assert_eq(idle.run_id, None)
    assert_eq(idle.phase, @workflow.Idle)
    assert_eq(idle.admitted, 0)
    assert_eq(idle.remaining_executions, 0)
    assert_eq(idle.blocked_count, 0)
    assert_eq(idle.reason, None)
    assert_true(idle.active.is_empty())
    assert_true(idle.board_revision is None)
    // Repeated reads admit nothing.
    for _ in 0..<16 {
      ignore(h.runner.status())
    }
    assert_eq(h.shared.runs, 0)
    assert_true(
      h.runner.start(parallel_spec(run_id="run-1", max_concurrency=2)) is Ok(_),
    )
    parallel_yield_until(what="wave in flight", check=() => {
      h.shared.entered.length() == 2
    })
    let active = h.runner.status()
    assert_eq(active.run_id, Some("run-1"))
    assert_eq(active.phase, @workflow.Running)
    assert_eq(active.max_concurrency, 2)
    assert_eq(active.active_count, 2)
    assert_eq(active.available_slots, 0)
    assert_eq(active.admitted, 2)
    assert_eq(active.blocked_count, 1)
    assert_eq(active.blocked[0].task_id, "delta")
    assert_true(
      active.blocked_reason_counts.contains({
        reason: @orchestration.TaskStageIneligible,
        count: 1,
      }),
    )
    // The explicit input reached the slot driver...
    assert_eq(h.shared.requests.length(), 2)
    for request in h.shared.requests {
      assert_true(request.input.contains("explicit parallel input"))
    }
    // ...but progress, the journal and the retained event stream stay
    // identity-only.
    for payload in parallel_event_payloads(h.backend) {
      assert_false(payload.contains("explicit parallel input"))
    }
    // Mutating the returned snapshots cannot corrupt the runner's state.
    let binding : @execution.BoardExecutionBinding = {
      task_id: "forged",
      attempt_id: "forged",
      execution_id: "forged",
      session_id: "forged",
      run: None,
      phase: @execution.Running,
      outcome: None,
    }
    active.active.push(binding)
    active.blocked.push({ task_id: "forged", attempt_id: None, reasons: [], })
    active.blocked[0].reasons.push(@orchestration.HostUnavailable)
    active.blocked_reason_counts.push({
      reason: @orchestration.HostUnavailable,
      count: 1,
    })
    let fresh = h.runner.status()
    assert_eq(fresh.active_count, 2)
    assert_eq(fresh.active.length(), 2)
    assert_eq(fresh.blocked_count, 1)
    assert_eq(fresh.blocked[0].reasons.length(), 1)
    assert_eq(fresh.blocked_reason_counts.length(), 1)
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 2)
    assert_false(bindings[0].execution_id == bindings[1].execution_id)
    // Still just reads: the held wave never grew.
    assert_eq(h.shared.runs, 2)
    assert_eq(h.shared.entered.length(), 2)
    h.shared.release("attempt-alpha-1")
    h.shared.release("attempt-beta-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.succeeded, 2)
    // Every adapter request carried exactly the input authorized for its own
    // bound execution identity, and no identity was shared.
    parallel_assert_journal(h)
    assert_true(status.active.is_empty())
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
