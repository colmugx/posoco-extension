///|
/// Planning integrity: stale replans with fresh identity, the dependency Done
/// gate with manual completion, frozen scope selection, the AllEligibleAtStart
/// snapshot, and stages the trusted-host policy never automates.

///|
async test "one stale plan is recomputed with fresh identity and no replay" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["alpha", "beta"], capacity=2, hold=[
      "attempt-alpha-1", "attempt-beta-1",
    ])
    h.resolver.stale_backend = Some(h.backend)
    h.resolver.stale_left = 1
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    parallel_yield_until(what="first wave", check=() => {
      h.shared.entered.length() == 2
    })
    // The first dispatch went stale after resolution: its authorization and
    // identities were discarded before any reservation, so nothing was
    // journalled or silently replayed. A sibling's durable Start can force
    // one further pre-admission re-authorization of the pinned candidate, so
    // the resolver log is longer than the admission log and only the last
    // authorization per Attempt is ever bound.
    let stale_identity = h.resolver.execution_ids[0]
    assert_true(h.resolver.execution_ids.length() >= 3)
    let alpha_auth = h.resolver.last_authorization_index("attempt-alpha-1")
    let beta_auth = h.resolver.last_authorization_index("attempt-beta-1")
    assert_true(alpha_auth > 0)
    assert_true(alpha_auth < beta_auth)
    h.shared.release("attempt-alpha-1")
    h.shared.release("attempt-beta-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 2)
    assert_eq(status.succeeded, 2)
    assert_eq(h.shared.runs, 2)
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 2)
    assert_eq(bindings[0].attempt_id, "attempt-alpha-1")
    assert_eq(bindings[1].attempt_id, "attempt-beta-1")
    assert_eq(bindings[0].execution_id, h.resolver.execution_ids[alpha_auth])
    assert_eq(bindings[0].session_id, h.resolver.session_ids[alpha_auth])
    assert_eq(bindings[1].execution_id, h.resolver.execution_ids[beta_auth])
    assert_eq(bindings[1].session_id, h.resolver.session_ids[beta_auth])
    // The discarded stale identity reached no journal and no Agent.
    for binding in bindings {
      assert_false(binding.execution_id == stale_identity)
    }
    parallel_assert_journal(h)
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
async test "a dependency blocks admission until it is manually Done" {
  @async.with_task_group(group => {
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta", "gamma"],
      capacity=2,
      hold=["attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1"],
    )
    parallel_command(h.backend, "board.task.set_dependencies", {
      "id": "beta",
      "dependencies": ["alpha"],
    })
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    parallel_yield_until(what="independent wave", check=() => {
      h.shared.entered.length() == 2
    })
    assert_true(
      parallel_same_ids(h.shared.entered_ids(), [
        "attempt-alpha-1", "attempt-gamma-1",
      ]),
    )
    // beta stays blocked: an Agent outcome never moves a Task to Done.
    let rows = h.runner.status().blocked.filter(row => row.task_id == "beta")
    assert_eq(rows.length(), 1)
    assert_true(
      rows[0].reasons.contains(@orchestration.DependencyNotDone("alpha")),
    )
    // A human moves alpha to Done while its execution is still held. The
    // attempt is Running but the Task itself is still Ready, so the only
    // legal stage path is Ready->Running->Review->Done.
    for stage in ["running", "review", "done"] {
      parallel_command(h.backend, "board.task.move", {
        "id": "alpha",
        "to": stage,
      })
    }
    h.shared.release("attempt-gamma-1")
    parallel_yield_until(what="gamma settled", check=() => {
      h.runner.status().settled == 1
    })
    h.shared.release("attempt-alpha-1")
    parallel_yield_until(what="dependency wave", check=() => {
      h.shared.entered_ids().contains("attempt-beta-1")
    })
    h.shared.release("attempt-beta-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 3)
    assert_eq(status.succeeded, 3)
    // The adapter ran each member exactly once; beta only after the wave
    // barrier, so both first-wave members precede it in run order. Extra
    // pre-admission re-authorizations never become extra Agent runs.
    assert_eq(h.shared.runs, 3)
    assert_eq(h.shared.run_order[2], "attempt-beta-1")
    assert_true(
      parallel_same_ids(h.shared.run_order, [
        "attempt-alpha-1", "attempt-gamma-1", "attempt-beta-1",
      ]),
    )
    parallel_assert_journal(h)
    let snapshot = h.backend.state().unwrap()
    assert_eq(
      snapshot.tasks.filter(task => task.id.value == "alpha")[0].stage,
      @domain.Done,
    )
    assert_eq(
      snapshot.tasks.filter(task => task.id.value == "beta")[0].stage,
      @domain.Ready,
    )
    assert_eq(status.board_revision, Some(snapshot.revision))
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "the runner copies the selected scope and never mutates caller state" {
  @async.with_task_group(group => {
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta", "gamma"],
      capacity=2,
      hold=["attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1"],
    )
    let selection = ["alpha", "beta"]
    assert_true(
      h.runner.start(
        parallel_spec(scope=@workflow.Selected(selection), max_concurrency=2),
      )
      is Ok(_),
    )
    // Caller-side mutation after start cannot widen the frozen scope.
    selection.push("gamma")
    selection.push("alpha")
    parallel_yield_until(what="selected wave", check=() => {
      h.shared.entered.length() == 2
    })
    h.shared.release("attempt-alpha-1")
    h.shared.release("attempt-beta-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.admitted, 2)
    assert_eq(status.succeeded, 2)
    assert_true(
      parallel_same_ids(h.shared.entered_ids(), [
        "attempt-alpha-1", "attempt-beta-1",
      ]),
    )
    // The runner never reordered, deduplicated or cleared the caller's array.
    assert_eq(selection, ["alpha", "beta", "gamma", "alpha"])
    assert_false(h.resolver.resolved_attempts.contains("attempt-gamma-1"))
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "tasks created after start stay outside the frozen scope" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["alpha", "beta"], capacity=2, hold=[
      "attempt-alpha-1", "attempt-beta-1",
    ])
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    parallel_yield_until(what="wave in flight", check=() => {
      h.shared.entered.length() == 2
    })
    // A new fully eligible task appears while the wave is active.
    parallel_task(h.backend, "zeta")
    h.shared.release("attempt-alpha-1")
    h.shared.release("attempt-beta-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 2)
    assert_eq(status.succeeded, 2)
    // zeta was eligible on the Board but was never authorized by this run:
    // only the two in-scope members were ever authorized or journalled.
    assert_false(h.resolver.resolved_attempts.contains("attempt-zeta-1"))
    assert_true(
      parallel_same_ids(h.shared.run_order, [
        "attempt-alpha-1", "attempt-beta-1",
      ]),
    )
    parallel_assert_journal(h)
    for binding in h.owner.bindings() {
      assert_false(binding.task_id == "zeta")
    }
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "Review-stage tasks are never auto-executed" {
  @async.with_task_group(group => {
    // The trusted host knows delta's input metadata too, so the Review stage
    // is delta's only reason to stay blocked; alpha is the work to admit.
    let h = parallel_harness(
      group,
      tasks=["alpha"],
      capacity=2,
      resolver=Some(
        parallel_resolver(available=[
          "alpha/attempt-alpha-1", "delta/attempt-delta-1",
        ]),
      ),
      hold=["attempt-alpha-1"],
    )
    // A human parked delta in Review with a queued Execute Attempt.
    parallel_task(h.backend, "delta")
    for stage in ["running", "review"] {
      parallel_command(h.backend, "board.task.move", {
        "id": "delta",
        "to": stage,
      })
    }
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    parallel_yield_until(what="alpha admitted", check=() => {
      h.shared.entered.length() == 1
    })
    let status = h.runner.status()
    assert_eq(status.blocked_count, 1)
    assert_eq(status.blocked[0].task_id, "delta")
    assert_true(
      status.blocked[0].reasons.contains(@orchestration.TaskStageIneligible),
    )
    h.shared.release("attempt-alpha-1")
    let done = h.runner.wait()
    assert_eq(done.phase, @workflow.Completed)
    assert_eq(done.reason, Some(@workflow.NoEligibleWork))
    assert_eq(done.admitted, 1)
    assert_eq(done.succeeded, 1)
    // The Review Attempt was never dispatched and stays queued untouched.
    assert_false(h.resolver.resolved_attempts.contains("attempt-delta-1"))
    let attempts = h.backend.state().unwrap().attempts.filter(attempt => {
      attempt.id.value == "attempt-delta-1"
    })
    assert_eq(attempts.length(), 1)
    assert_eq(attempts[0].status, @domain.Queued)
    assert_eq(
      h.backend.state().unwrap().tasks.filter(task => task.id.value == "delta")[0].stage,
      @domain.Review,
    )
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
