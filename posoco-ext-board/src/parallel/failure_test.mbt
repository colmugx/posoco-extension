///|
/// Failure containment: the three confirmed-failure policies over one shared
/// wave, and the unresolved settlement that overrides every policy, cancels
/// siblings by identity and blocks any further admission.

///|
async test "a confirmed failure stops after the wave under the default policy" {
  @async.with_task_group(group => {
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta", "gamma"],
      capacity=2,
      hold=["attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1"],
      fail=["attempt-alpha-1"],
    )
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    // Deterministic queue handshake: both members are inside their runs
    // before the failing one is released. An instant failure legitimately
    // withdraws the sibling's admission, so the wave containment below must
    // not race it.
    parallel_yield_until(what="wave in flight", check=() => {
      h.shared.entered.length() == 2
    })
    // The failing member settles first; the sibling still settles normally
    // under StopOnFailure and the wave ends after both confirm.
    h.shared.release("attempt-alpha-1")
    h.shared.release("attempt-beta-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Failed)
    assert_eq(status.reason, Some(@workflow.ExecutionFailed(@execution.Failed)))
    assert_eq(status.admitted, 2)
    assert_eq(status.failed, 1)
    assert_eq(status.succeeded, 1)
    // gamma is never admitted after the confirmed failure.
    assert_false(h.resolver.resolved_attempts.contains("attempt-gamma-1"))
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 2)
    assert_eq(bindings[0].attempt_id, "attempt-alpha-1")
    assert_eq(bindings[1].attempt_id, "attempt-beta-1")
    assert_eq(bindings[0].outcome, Some(@execution.Failed))
    assert_eq(bindings[1].outcome, Some(@execution.Completed))
    parallel_assert_journal(h)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "confirmed failures continue to the next wave under the continuing policy" {
  @async.with_task_group(group => {
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta", "gamma", "delta"],
      capacity=2,
      hold=[
        "attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1", "attempt-delta-1",
      ],
      fail=["attempt-alpha-1"],
    )
    assert_true(
      h.runner.start(
        parallel_spec(
          max_concurrency=2,
          failure_policy=@parallel.ContinueOnConfirmedFailure,
        ),
      )
      is Ok(_),
    )
    // Handshake: both first-wave members are inside their runs before the
    // failing one is released, so the confirmed failure cannot race beta's
    // admission out of the wave.
    parallel_yield_until(what="first wave", check=() => {
      h.shared.entered.length() == 2
    })
    h.shared.release("attempt-alpha-1")
    h.shared.release("attempt-beta-1")
    parallel_yield_until(what="second wave", check=() => {
      h.shared.entered.length() == 4
    })
    h.shared.release("attempt-gamma-1")
    h.shared.release("attempt-delta-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 4)
    assert_eq(status.failed, 1)
    assert_eq(status.succeeded, 3)
    // Exactly four Agent runs, one per member: extra pre-admission
    // re-authorizations never become extra admissions.
    assert_eq(h.shared.runs, 4)
    assert_true(
      parallel_same_ids(h.shared.run_order, [
        "attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1", "attempt-delta-1",
      ]),
    )
    parallel_assert_journal(h)
    let bindings = h.owner.bindings()
    assert_eq(bindings[0].outcome, Some(@execution.Failed))
    assert_eq(bindings[1].outcome, Some(@execution.Completed))
    assert_eq(bindings[2].outcome, Some(@execution.Completed))
    assert_eq(bindings[3].outcome, Some(@execution.Completed))
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "cancel remaining withdraws and cancels the still-running sibling" {
  @async.with_task_group(group => {
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta", "gamma"],
      capacity=2,
      hold=["attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1"],
      fail=["attempt-alpha-1"],
    )
    assert_true(
      h.runner.start(
        parallel_spec(
          max_concurrency=2,
          failure_policy=@parallel.CancelRemainingOnFailure,
        ),
      )
      is Ok(_),
    )
    // Handshake: both members are inside their runs before the failing one is
    // released, so beta's cancellation below comes from the policy's
    // identity-based withdrawal, not from a lost admission race.
    parallel_yield_until(what="wave in flight", check=() => {
      h.shared.entered.length() == 2
    })
    h.shared.release("attempt-alpha-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Failed)
    assert_eq(status.reason, Some(@workflow.ExecutionFailed(@execution.Failed)))
    assert_eq(status.admitted, 2)
    assert_eq(status.failed, 1)
    assert_eq(status.cancelled, 1)
    assert_eq(status.succeeded, 0)
    // gamma is never admitted; the held beta was cancelled by identity and
    // never released by the test.
    assert_false(h.resolver.resolved_attempts.contains("attempt-gamma-1"))
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 2)
    assert_eq(bindings[0].attempt_id, "attempt-alpha-1")
    assert_eq(bindings[1].attempt_id, "attempt-beta-1")
    assert_eq(bindings[0].outcome, Some(@execution.Failed))
    assert_eq(bindings[1].outcome, Some(@execution.Cancelled))
    parallel_assert_journal(h)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "an unconfirmed settlement overrides every policy and cancels siblings" {
  for
    policy in [
      @parallel.StopOnFailure,
      @parallel.ContinueOnConfirmedFailure,
      @parallel.CancelRemainingOnFailure,
    ] {
    @async.with_task_group(group => {
      let h = parallel_harness(
        group,
        tasks=["alpha", "beta", "gamma"],
        capacity=2,
        hold=["attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1"],
        nogate=["attempt-alpha-1"],
      )
      assert_true(
        h.runner.start(parallel_spec(max_concurrency=2, failure_policy=policy))
        is Ok(_),
      )
      // Handshake: both members are inside their runs before the unresolved
      // one is released, so beta's cancellation below is the unresolved
      // override acting on an admitted sibling, not an admission race.
      parallel_yield_until(what="wave in flight", check=() => {
        h.shared.entered.length() == 2
      })
      h.shared.release("attempt-alpha-1")
      let status = h.runner.wait()
      assert_eq(status.phase, @workflow.Unresolved)
      assert_eq(status.reason, Some(@workflow.UnconfirmedSettlement))
      assert_eq(status.admitted, 2)
      assert_eq(status.succeeded, 0)
      // The unresolved member overrides every policy: nothing is confirmed as
      // settled, so the identity-cancelled sibling is not counted either.
      assert_eq(status.settled, 0)
      assert_eq(status.cancelled, 0)
      // gamma is never admitted; the held beta was cancelled by identity and
      // never released by the test.
      assert_false(h.resolver.resolved_attempts.contains("attempt-gamma-1"))
      let bindings = h.owner.bindings()
      assert_eq(bindings.length(), 2)
      assert_eq(bindings[0].phase, @execution.Unresolved)
      assert_eq(bindings[0].outcome, Some(@execution.Interrupted))
      // Withdrawn by identity while still held: the outcome is Cancelled, and
      // the poisoned owner leaves the settlement unconfirmed for host cleanup.
      assert_eq(bindings[1].attempt_id, "attempt-beta-1")
      assert_eq(bindings[1].outcome, Some(@execution.Cancelled))
      assert_eq(bindings[1].phase, @execution.Unresolved)
      // An unresolved loop keeps ownership: restart needs a resolved owner.
      assert_true(
        h.runner.start(parallel_spec(run_id="fresh", max_concurrency=2))
        is Err(@workflow.UnresolvedOwner),
      )
      assert_eq(h.shared.runs, 2)
      assert_true(h.runner.shutdown())
      h.backend.shutdown()
    })
  }
}
