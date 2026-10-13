///|
/// Recovery over the shared v1 journal: any recovered non-settled binding
/// blocks the whole namespace without automatic execution, while settled
/// history only marks those identities spent.

///|
/// Preloaded journal for restart scenarios; every persist replaces wholesale.
struct ParallelJournal {
  mut records : Array[@execution.BoardExecutionBinding]
}

///|
impl @execution.BoardExecutionStore for ParallelJournal with fn load(self) {
  Ok(self.records.copy())
}

///|
impl @execution.BoardExecutionStore for ParallelJournal with fn persist(
  self,
  records,
) {
  self.records = records.copy()
  Ok(())
}

///|
fn parallel_journal(
  records : Array[@execution.BoardExecutionBinding],
) -> ParallelJournal {
  { records: records.copy(), }
}

///|
/// One settled historical binding: evidence of termination, not permission.
fn settled_record(
  task_id : String,
  attempt_id : String,
  execution_id : String,
) -> @execution.BoardExecutionBinding {
  {
    task_id,
    attempt_id,
    execution_id,
    session_id: "\{execution_id}-session",
    run: Some({
      session_id: "\{execution_id}-session",
      run_id: "\{execution_id}-run",
      turn_id: "\{execution_id}-turn",
    }),
    phase: @execution.Settled,
    outcome: Some(@execution.Completed),
  }
}

///|
/// One recovered, never-settled binding: well-formed per the v1 journal, so
/// only its non-settled phase locks admission.
fn running_record(
  task_id : String,
  attempt_id : String,
  execution_id : String,
) -> @execution.BoardExecutionBinding {
  {
    ..settled_record(task_id, attempt_id, execution_id),
    phase: @execution.Running,
    outcome: None,
  }
}

///|
async test "a recovered mixed journal blocks start and never auto-executes" {
  @async.with_task_group(group => {
    let journal = parallel_journal([
      settled_record("alpha", "attempt-alpha-1", "settled-exec"),
      running_record("beta", "attempt-beta-1", "recovered-exec"),
    ])
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta"],
      capacity=2,
      store=journal,
    )
    assert_true(h.owner.status().unresolved)
    assert_eq(h.shared.runs, 0)
    // Authorization is refused before any admission or identity write.
    assert_true(
      h.runner.start(parallel_spec(max_concurrency=2))
      is Err(@workflow.UnresolvedOwner),
    )
    // A paused host never repairs, reconciles or replays by itself.
    for _ in 0..<64 {
      @async.pause()
      assert_eq(h.shared.runs, 0)
      assert_eq(h.resolver.execution_ids.length(), 0)
    }
    assert_eq(journal.records.length(), 2)
    assert_eq(journal.records[0].phase, @execution.Settled)
    assert_eq(journal.records[1].phase, @execution.Running)
    assert_true(journal.records[1].outcome is None)
    assert_true(
      h.runner.start(parallel_spec(run_id="retry", max_concurrency=2))
      is Err(@workflow.UnresolvedOwner),
    )
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "settled history is never reused and fresh attempts run with fresh identity" {
  @async.with_task_group(group => {
    let journal = parallel_journal([
      settled_record("alpha", "attempt-alpha-1", "spent-exec"),
    ])
    let h = parallel_harness(
      group,
      tasks=["alpha", "beta"],
      capacity=2,
      store=journal,
    )
    assert_false(h.owner.status().unresolved)
    assert_true(h.runner.start(parallel_spec(max_concurrency=2)) is Ok(_))
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Completed)
    assert_eq(status.reason, Some(@workflow.NoEligibleWork))
    assert_eq(status.admitted, 1)
    assert_eq(status.succeeded, 1)
    // The spent Attempt is blocked for the whole namespace and never replays.
    let rows = h.runner.status().blocked.filter(row => row.task_id == "alpha")
    assert_eq(rows.length(), 1)
    assert_true(rows[0].reasons.contains(@orchestration.IdentityAlreadyUsed))
    assert_eq(h.shared.runs, 1)
    assert_eq(h.shared.run_order, ["attempt-beta-1"])
    assert_eq(h.resolver.execution_ids, ["parallel-exec-1"])
    assert_false(h.resolver.execution_ids[0] == "spent-exec")
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 2)
    assert_eq(bindings[0].attempt_id, "attempt-alpha-1")
    assert_eq(bindings[0].execution_id, "spent-exec")
    assert_eq(bindings[1].attempt_id, "attempt-beta-1")
    assert_eq(bindings[1].execution_id, "parallel-exec-1")
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
