///|
/// Host control surface: pause/resume, stop-after-wave, cancel of every
/// occupied identity, the independent workflow deadline, shutdown of a held
/// wave, and duplicate or concurrent start rejection.

///|
async test "pause withdraws admission until the in-flight wave settles" {
  @async.with_task_group(group => {
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta", "gamma"],
      capacity=2,
      hold=["attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1"],
    )
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    parallel_yield_until(what="wave in flight", check=() => {
      h.shared.entered.length() == 2
    })
    assert_true(h.runner.pause())
    assert_eq(h.runner.status().phase, @workflow.Pausing)
    // Pausing a pausing runner is not a new request.
    assert_false(h.runner.pause())
    h.shared.release("attempt-alpha-1")
    h.shared.release("attempt-beta-1")
    parallel_wait_phase(h, @workflow.Paused)
    let paused = h.runner.status()
    assert_eq(paused.admitted, 2)
    assert_eq(paused.succeeded, 2)
    assert_eq(paused.active_count, 0)
    assert_eq(paused.available_slots, 2)
    // gamma waits for resume; nothing was authorized while paused.
    assert_false(h.resolver.resolved_attempts.contains("attempt-gamma-1"))
    assert_eq(h.owner.bindings().length(), 2)
    assert_true(h.runner.resume_workflow())
    assert_eq(h.runner.status().phase, @workflow.Running)
    // Resuming a running runner is not a new request.
    assert_false(h.runner.resume_workflow())
    parallel_yield_until(what="resumed wave", check=() => {
      h.shared.entered.length() == 3
    })
    assert_true(h.shared.entered_ids().contains("attempt-gamma-1"))
    h.shared.release("attempt-gamma-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 3)
    assert_eq(status.succeeded, 3)
    // Controls on a finished run are refused and cancel stays a no-op.
    assert_false(h.runner.pause())
    assert_false(h.runner.resume_workflow())
    assert_false(h.runner.stop_after_wave())
    h.runner.cancel()
    assert_eq(h.runner.status().phase, @workflow.Completed)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "pausing before the first dispatch admits nothing until resume" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["alpha", "beta"], capacity=2)
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    assert_true(h.runner.pause())
    parallel_wait_phase(h, @workflow.Paused)
    assert_eq(h.shared.runs, 0)
    assert_eq(h.runner.status().admitted, 0)
    assert_eq(h.runner.status().active_count, 0)
    assert_true(h.runner.resume_workflow())
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.succeeded, 2)
    // Both members were admitted in planning order once resumed; a sibling's
    // durable Start can add pre-admission re-authorizations, so the bound
    // journal identities, not the resolver call log, carry the order.
    assert_eq(h.owner.bindings()[0].attempt_id, "attempt-alpha-1")
    assert_eq(h.owner.bindings()[1].attempt_id, "attempt-beta-1")
    let alpha_auth = h.resolver.last_authorization_index("attempt-alpha-1")
    let beta_auth = h.resolver.last_authorization_index("attempt-beta-1")
    assert_true(alpha_auth < beta_auth)
    parallel_assert_journal(h)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "stop after wave lets both members settle then stops admission" {
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
    parallel_yield_until(what="wave in flight", check=() => {
      h.shared.entered.length() == 2
    })
    assert_true(h.runner.stop_after_wave())
    assert_eq(h.runner.status().phase, @workflow.Stopping)
    // Stopping is not re-requestable once withdrawal began.
    assert_false(h.runner.stop_after_wave())
    // No implicit cancellation: both members still run to completion.
    h.shared.release("attempt-alpha-1")
    h.shared.release("attempt-beta-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Stopped)
    assert_eq(status.reason, Some(@workflow.StopRequested))
    assert_eq(status.admitted, 2)
    assert_eq(status.succeeded, 2)
    // Admission stopped after the wave: gamma and delta stay unauthorized.
    assert_false(h.resolver.resolved_attempts.contains("attempt-gamma-1"))
    assert_false(h.resolver.resolved_attempts.contains("attempt-delta-1"))
    for binding in h.owner.bindings() {
      assert_eq(binding.phase, @execution.Settled)
      assert_eq(binding.outcome, Some(@execution.Completed))
    }
    parallel_assert_journal(h)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "stop after wave from paused ends the run without admissions" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["alpha", "beta"], capacity=2)
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    assert_true(h.runner.pause())
    parallel_wait_phase(h, @workflow.Paused)
    assert_true(h.runner.stop_after_wave())
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Stopped)
    assert_eq(status.reason, Some(@workflow.StopRequested))
    assert_eq(status.admitted, 0)
    assert_eq(h.shared.runs, 0)
    assert_true(h.owner.bindings().is_empty())
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "cancel cancels every occupied identity at once" {
  @async.with_task_group(group => {
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta", "gamma"],
      capacity=2,
      hold=["attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1"],
    )
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    parallel_yield_until(what="wave in flight", check=() => {
      h.shared.entered.length() == 2
    })
    h.runner.cancel()
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Stopped)
    assert_eq(status.reason, Some(@workflow.CancelRequested))
    assert_eq(status.admitted, 2)
    assert_eq(status.succeeded, 0)
    assert_eq(status.cancelled, 2)
    // No further admission: gamma is never authorized.
    assert_false(h.resolver.resolved_attempts.contains("attempt-gamma-1"))
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 2)
    for binding in bindings {
      assert_eq(binding.phase, @execution.Settled)
      assert_eq(binding.outcome, Some(@execution.Cancelled))
    }
    parallel_assert_journal(h)
    // Cancelling a finished run is a no-op.
    h.runner.cancel()
    assert_eq(h.runner.status().phase, @workflow.Stopped)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "cancel before the worker enters leaves nothing occupied" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["alpha", "beta"], capacity=2)
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    h.runner.cancel()
    h.runner.cancel()
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Stopped)
    assert_eq(status.reason, Some(@workflow.CancelRequested))
    assert_eq(status.admitted, 0)
    assert_eq(h.shared.runs, 0)
    assert_true(h.owner.bindings().is_empty())
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "the structured deadline cancels the whole wave and stops admission" {
  @async.with_task_group(group => {
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta", "gamma"],
      capacity=2,
      hold=["attempt-alpha-1", "attempt-beta-1", "attempt-gamma-1"],
    )
    assert_true(
      h.runner.start(
        parallel_spec(
          max_elapsed_ms=300,
          execution_timeout_ms=300,
          max_concurrency=2,
        ),
      )
      is Ok(_),
    )
    parallel_yield_until(what="wave in flight", check=() => {
      h.shared.entered.length() == 2
    })
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Stopped)
    assert_eq(status.reason, Some(@workflow.DeadlineReached))
    assert_eq(status.admitted, 2)
    assert_eq(status.succeeded, 0)
    // The wave deadline ties with the members' own execution budget, so each
    // held run settles terminally without success: withdrawn by identity
    // (Cancelled) or expired on its own budget (TimedOut). Either way the
    // wave ends with no confirmed success and admission stays stopped.
    assert_eq(status.cancelled + status.failed, 2)
    // Admission is stopped with the deadline: gamma is never authorized.
    assert_false(h.resolver.resolved_attempts.contains("attempt-gamma-1"))
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 2)
    for binding in bindings {
      assert_eq(binding.phase, @execution.Settled)
      assert_true(
        binding.outcome == Some(@execution.Cancelled) ||
        binding.outcome == Some(@execution.TimedOut),
      )
    }
    parallel_assert_journal(h)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "shutdown during a held wave cancels joins and closes admission" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["alpha", "beta"], capacity=2, hold=[
      "attempt-alpha-1", "attempt-beta-1",
    ])
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    parallel_yield_until(what="wave in flight", check=() => {
      h.shared.entered.length() == 2
    })
    assert_true(h.runner.shutdown(timeout_ms=4000))
    let status = h.runner.status()
    assert_eq(status.phase, @workflow.Stopped)
    assert_eq(status.reason, Some(@workflow.HostShutdown))
    assert_eq(status.admitted, 2)
    assert_eq(status.cancelled, 2)
    for binding in h.owner.bindings() {
      assert_eq(binding.outcome, Some(@execution.Cancelled))
    }
    assert_true(
      h.runner.start(parallel_spec(run_id="late", max_concurrency=2))
      is Err(@workflow.Closed),
    )
    // Repeated shutdown stays confirmed and idempotent.
    assert_true(h.runner.shutdown())
    assert_true(h.orchestrator.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "duplicate and concurrent starts are rejected while one authorization owns the runner" {
  @async.with_task_group(group => {
    let h = parallel_harness(group, tasks=["alpha", "beta"], capacity=2, hold=[
      "attempt-alpha-1", "attempt-beta-1",
    ])
    assert_true(
      h.runner.start(parallel_spec(run_id="run-1", max_concurrency=2)) is Ok(_),
    )
    parallel_yield_until(what="wave in flight", check=() => {
      h.shared.entered.length() == 2
    })
    // A second authorization may not run while one loop owns the runner.
    assert_true(
      h.runner.start(parallel_spec(run_id="run-2", max_concurrency=2))
      is Err(@workflow.AlreadyRunning),
    )
    // Even a truly concurrent start sees the reserved runner.
    let racing = group.spawn(() => {
      h.runner.start(parallel_spec(run_id="run-3", max_concurrency=2))
    })
    parallel_yield_until(what="racing start", check=() => {
      (racing.try_wait() is Some(_)) catch {
        _ => true
      }
    })
    assert_true(racing.wait() is Err(@workflow.AlreadyRunning))
    h.shared.release("attempt-alpha-1")
    h.shared.release("attempt-beta-1")
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.succeeded, 2)
    // The consumed run identity is rejected without touching state.
    assert_true(
      h.runner.start(parallel_spec(run_id="run-1", max_concurrency=2))
      is Err(@workflow.DuplicateRunIdentity),
    )
    assert_eq(h.shared.runs, 2)
    // New explicit authorization restarts; every Attempt is spent.
    assert_true(
      h.runner.start(parallel_spec(run_id="run-4", max_concurrency=2)) is Ok(_),
    )
    let second = h.runner.wait()
    assert_eq(second.phase, @workflow.Completed)
    assert_eq(second.run_id, Some("run-4"))
    assert_eq(second.admitted, 0)
    assert_eq(h.shared.runs, 2)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
