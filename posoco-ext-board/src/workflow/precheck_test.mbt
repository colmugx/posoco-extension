///|
/// Admission prechecks: the loop consults the scoped orchestrator status
/// before every dispatch. A disabled execution policy, a denied or missing
/// input hint, and a recovered unresolved journal each stop the run without
/// silent fallback or any execution effect.

///|
async test "the safe disabled policy stops the loop as OrchestrationBlocked" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha"], policy_enabled=false)
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Failed))
    assert_eq(
      status.reason,
      Some(@workflow.OrchestrationBlocked(@orchestration.AdmissionDisabled)),
    )
    assert_eq(status.admitted, 0)
    assert_eq(h.adapter.runs, 0)
    assert_true(h.owner.bindings().is_empty())
    assert_eq(h.resolver.execution_ids.length(), 0)
    // The loop still observed the Board before stopping.
    assert_eq(status.board_revision, Some(h.backend.state().unwrap().revision))
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "a denied input stops the run without falling back to another task" {
  @async.with_task_group(group => {
    let resolver = scripted_resolver(available=["alpha/attempt-alpha-1"])
    resolver.denied.push("beta/attempt-beta-1")
    let h = workflow_harness(
      group,
      tasks=["alpha", "beta"],
      resolver=Some(resolver),
    )
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    let status = h.runner.wait()
    assert_true(workflow_phase_eq(status.phase, @workflow.Failed))
    assert_eq(
      status.reason,
      Some(@workflow.AdmissionRejected(@orchestration.AuthorizationRejected)),
    )
    // No fallback substitution: not even the available alpha ran.
    assert_eq(status.admitted, 0)
    assert_eq(h.adapter.runs, 0)
    assert_true(h.owner.bindings().is_empty())
    assert_eq(h.resolver.execution_ids.length(), 0)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
/// Preloaded journal with one recovered, never-settled execution. Its
/// presence poisons the owner: execution admission stays locked until an
/// operator reconciles it outside this API.
struct RecoveredJournal {
  mut records : Array[@execution.BoardExecutionBinding]
}

///|
impl @execution.BoardExecutionStore for RecoveredJournal with fn load(self) {
  Ok(self.records.copy())
}

///|
impl @execution.BoardExecutionStore for RecoveredJournal with fn persist(
  self,
  records,
) {
  self.records = records.copy()
  Ok(())
}

///|
/// One recovered, never-settled execution: it entered its run scope and was
/// durably started, but never settled. Well-formed per the journal format, so
/// only its non-settled phase locks admission.
fn recovered_journal() -> RecoveredJournal {
  {
    records: [
      {
        task_id: "alpha",
        attempt_id: "attempt-alpha-1",
        execution_id: "recovered-exec",
        session_id: "recovered-session",
        run: Some({
          session_id: "recovered-session",
          run_id: "recovered-run",
          turn_id: "recovered-turn",
        }),
        phase: @execution.Running,
        outcome: None,
      },
    ],
  }
}

///|
async test "a recovered unresolved journal stays unresolved even on an empty board" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=[], store=recovered_journal())
    assert_true(h.runner.start(workflow_spec(run_id="run-1")) is Ok(_))
    let status = h.runner.wait()
    // An empty Board would otherwise be Completed/NoEligibleWork; unresolved
    // ownership always wins.
    assert_true(workflow_phase_eq(status.phase, @workflow.Unresolved))
    assert_eq(status.reason, Some(@workflow.UnconfirmedSettlement))
    assert_eq(status.admitted, 0)
    assert_eq(h.adapter.runs, 0)
    // The recovered record is preserved untouched: no settlement, no replay.
    let bindings = h.owner.bindings()
    assert_eq(bindings.length(), 1)
    assert_eq(bindings[0].execution_id, "recovered-exec")
    assert_eq(bindings[0].phase, @execution.Running)
    assert_true(bindings[0].outcome is None)
    // Restart needs a resolved owner.
    assert_true(
      h.runner.start(workflow_spec(run_id="run-2"))
      is Err(@workflow.UnresolvedOwner),
    )
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}
