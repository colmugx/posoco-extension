///|
/// Bounded fan-out: deterministic planning order, simultaneous isolated slots,
/// capacity and count bounds, and the wave barrier that holds back the next
/// wave until every member confirms settled.

///|
async test "two slots run two tasks simultaneously in deterministic admission order" {
  @async.with_task_group(group => {
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta", "gamma"],
      capacity=2,
      hold=["attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1"],
    )
    assert_eq(h.shared.slots, 2)
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    parallel_yield_until(what="two slots occupied", check=() => {
      h.shared.entered.length() == 2
    })
    // Admission is serialized in deterministic planning order even though the
    // two runs overlap. A sibling's durable Start can force one extra
    // pre-admission re-authorization of the pinned candidate, so the resolver
    // log is not an admission log; the admitted authorization is always the
    // last one recorded for that Attempt.
    let alpha_auth = h.resolver.last_authorization_index("attempt-alpha-1")
    let beta_auth = h.resolver.last_authorization_index("attempt-beta-1")
    assert_true(alpha_auth < beta_auth)
    assert_true(
      parallel_same_ids(h.shared.entered_ids(), [
        "attempt-alpha-1", "attempt-beta-1",
      ]),
    )
    let slots = h.shared.entered_slots()
    assert_false(slots[0] == slots[1])
    assert_eq(h.shared.max_active, 2)
    let active = h.runner.status()
    assert_eq(active.phase, @workflow.Running)
    assert_eq(active.max_concurrency, 2)
    assert_eq(active.active_count, 2)
    assert_eq(active.available_slots, 0)
    assert_eq(active.admitted, 2)
    assert_eq(active.remaining_executions, 8)
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 2)
    assert_eq(bindings[0].attempt_id, "attempt-alpha-1")
    assert_eq(bindings[1].attempt_id, "attempt-beta-1")
    assert_eq(bindings[0].execution_id, h.resolver.execution_ids[alpha_auth])
    assert_eq(bindings[1].execution_id, h.resolver.execution_ids[beta_auth])
    assert_false(bindings[0].session_id == bindings[1].session_id)
    // Each run owns exactly one isolated slot driver.
    assert_eq(h.shared.runs, 2)
    h.shared.release("attempt-alpha-1")
    h.shared.release("attempt-beta-1")
    parallel_yield_until(what="second wave", check=() => {
      h.shared.entered.length() == 3
    })
    assert_true(h.shared.entered_ids().contains("attempt-gamma-1"))
    h.shared.release("attempt-gamma-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 3)
    assert_eq(status.settled, 3)
    assert_eq(status.succeeded, 3)
    assert_eq(h.shared.max_active, 2)
    let settled = h.owner.bindings()
    assert_eq(settled.length(), 3)
    for binding in settled {
      assert_eq(binding.phase, @execution.Settled)
      assert_eq(binding.outcome, Some(@execution.Completed))
    }
    // Three journalled runs, each bound to one fresh, distinct authorization.
    parallel_assert_journal(h)
    assert_eq(status.board_revision, Some(h.backend.state().unwrap().revision))
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "the default concurrency runs one execution at a time" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["alpha", "beta", "gamma"])
    assert_eq(h.shared.slots, 1)
    assert_true(h.runner.start(parallel_spec()) is Ok(_))
    assert_eq(h.runner.status().max_concurrency, 1)
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 3)
    assert_eq(status.succeeded, 3)
    // Strict sequencing with the one default slot.
    assert_eq(h.shared.run_order, [
      "attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1",
    ])
    assert_eq(h.shared.max_active, 1)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "three slots bound five tasks to three simultaneous admissions" {
  @async.with_task_group(group => {
    let h = parallel_harness(
      group,
      tasks=["t1", "t2", "t3", "t4", "t5"],
      capacity=3,
      hold=[
        "attempt-t1-1", "attempt-t2-1", "attempt-t3-1", "attempt-t4-1", "attempt-t5-1",
      ],
    )
    assert_true(h.runner.start(parallel_spec(max_concurrency=3)) is Ok(_))
    parallel_yield_until(what="full wave", check=() => {
      h.shared.entered.length() == 3
    })
    assert_true(
      parallel_same_ids(h.shared.entered_ids(), [
        "attempt-t1-1", "attempt-t2-1", "attempt-t3-1",
      ]),
    )
    let slots = h.shared.entered_slots()
    assert_false(slots[0] == slots[1])
    assert_false(slots[0] == slots[2])
    assert_false(slots[1] == slots[2])
    let active = h.runner.status()
    assert_eq(active.active_count, 3)
    assert_eq(active.available_slots, 0)
    assert_eq(active.admitted, 3)
    assert_eq(h.shared.max_active, 3)
    // t4 and t5 wait for the wave barrier even though planning saw them: no
    // authorization was ever spent on them.
    assert_false(h.resolver.resolved_attempts.contains("attempt-t4-1"))
    assert_false(h.resolver.resolved_attempts.contains("attempt-t5-1"))
    h.shared.release("attempt-t1-1")
    h.shared.release("attempt-t2-1")
    h.shared.release("attempt-t3-1")
    parallel_yield_until(what="second wave", check=() => {
      h.shared.entered.length() == 5
    })
    assert_true(
      parallel_same_ids(h.shared.entered_ids(), [
        "attempt-t1-1", "attempt-t2-1", "attempt-t3-1", "attempt-t4-1", "attempt-t5-1",
      ]),
    )
    h.shared.release("attempt-t4-1")
    h.shared.release("attempt-t5-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 5)
    assert_eq(status.succeeded, 5)
    assert_eq(h.shared.max_active, 3)
    // Each of the five members ran exactly once and stays bound to one exact
    // fresh authorization; the planning order of the two serialized waves is
    // visible in the last authorization per Attempt.
    assert_true(
      parallel_same_ids(h.shared.run_order, [
        "attempt-t1-1", "attempt-t2-1", "attempt-t3-1", "attempt-t4-1", "attempt-t5-1",
      ]),
    )
    let t1_auth = h.resolver.last_authorization_index("attempt-t1-1")
    let t2_auth = h.resolver.last_authorization_index("attempt-t2-1")
    let t3_auth = h.resolver.last_authorization_index("attempt-t3-1")
    let t4_auth = h.resolver.last_authorization_index("attempt-t4-1")
    let t5_auth = h.resolver.last_authorization_index("attempt-t5-1")
    assert_true(t1_auth < t2_auth)
    assert_true(t2_auth < t3_auth)
    assert_true(t4_auth < t5_auth)
    parallel_assert_journal(h)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "the count budget bounds a wave below the free capacity" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["t1", "t2", "t3"], capacity=3, hold=[
      "attempt-t1-1", "attempt-t2-1",
    ])
    assert_true(
      h.runner.start(parallel_spec(max_concurrency=3, max_executions=2))
      is Ok(_),
    )
    parallel_yield_until(what="budgeted wave", check=() => {
      h.shared.entered.length() == 2
    })
    assert_true(
      parallel_same_ids(h.shared.entered_ids(), ["attempt-t1-1", "attempt-t2-1"]),
    )
    let active = h.runner.status()
    assert_eq(active.admitted, 2)
    assert_eq(active.remaining_executions, 0)
    // The third slot stays empty: the count budget, not capacity, bound it.
    assert_false(h.resolver.resolved_attempts.contains("attempt-t3-1"))
    assert_eq(h.owner.bindings().length(), 2)
    h.shared.release("attempt-t1-1")
    h.shared.release("attempt-t2-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.reason, Some(@workflow.ExecutionBudgetReached))
    assert_eq(status.admitted, 2)
    assert_eq(h.shared.runs, 2)
    assert_eq(h.owner.bindings().length(), 2)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "a wave above the owner capacity is an invalid specification" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["alpha", "beta"], capacity=2, hold=[
      "attempt-alpha-1", "attempt-beta-1",
    ])
    assert_true(
      h.runner.start(parallel_spec(run_id="too-wide", max_concurrency=3))
      is Err(@workflow.InvalidSpec),
    )
    assert_eq(h.shared.runs, 0)
    assert_true(h.owner.bindings().is_empty())
    assert_true(
      h.runner.start(parallel_spec(run_id="fits", max_concurrency=2)) is Ok(_),
    )
    parallel_yield_until(what="two slots", check=() => {
      h.shared.entered.length() == 2
    })
    h.shared.release("attempt-alpha-1")
    h.shared.release("attempt-beta-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.succeeded, 2)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "a slow member holds the wave barrier against settled siblings" {
  @async.with_task_group(group => {
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta", "gamma", "delta"],
      capacity=2,
      hold=[
        "attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1", "attempt-delta-1",
      ],
    )
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    parallel_yield_until(what="first wave", check=() => {
      h.shared.entered.length() == 2
    })
    // Out-of-order fan-in: beta settles first and frees a slot.
    h.shared.release("attempt-beta-1")
    parallel_yield_until(what="beta settled", check=() => {
      h.runner.status().settled == 1
    })
    let partial = h.runner.status()
    assert_eq(partial.phase, @workflow.Running)
    assert_eq(partial.active_count, 1)
    assert_eq(partial.available_slots, 1)
    assert_eq(partial.succeeded, 1)
    assert_eq(partial.admitted, 2)
    // The freed slot never triggers the next wave while alpha still runs: no
    // further authorization and no further entry beyond the held sibling.
    let authorized = h.resolver.resolved_attempts.length()
    for _ in 0..<64 {
      @async.pause()
      assert_eq(h.resolver.resolved_attempts.length(), authorized)
      assert_eq(h.shared.entered.length(), 2)
      assert_eq(h.runner.status().phase, @workflow.Running)
    }
    h.shared.release("attempt-alpha-1")
    parallel_yield_until(what="second wave", check=() => {
      h.shared.entered.length() == 4
    })
    assert_true(
      parallel_same_ids(h.shared.entered_ids(), [
        "attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1", "attempt-delta-1",
      ]),
    )
    h.shared.release("attempt-gamma-1")
    h.shared.release("attempt-delta-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 4)
    assert_eq(status.succeeded, 4)
    assert_eq(h.shared.runs, 4)
    assert_true(
      parallel_same_ids(h.shared.run_order, [
        "attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1", "attempt-delta-1",
      ]),
    )
    parallel_assert_journal(h)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
