///|
struct WithdrawalProbe {
  mut inspections : Int32
}

///|
impl @orchestration.BoardExecutionInputResolver for WithdrawalProbe with fn availability(
  self,
  _candidate,
) {
  self.inspections += 1
  // Fault injection: initial and post-resolution inspection authorize, then
  // host permission is withdrawn at the owner's last-line reservation guard.
  if self.inspections <= 2 {
    @orchestration.Available
  } else {
    @orchestration.Denied
  }
}

///|
impl @orchestration.BoardExecutionInputResolver for WithdrawalProbe with fn resolve(
  _self,
  _candidate,
) {
  @orchestration.Authorized({
    execution_id: "reserved-exec",
    session_id: "reserved-session",
    input: "explicit",
    timeout_ms: None,
  })
}

///|
async test "owner reservation guard rejection returns fresh StalePlan without journal or execution" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    let journal = orch_journal()
    let adapter = orch_adapter()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    let resolver = WithdrawalProbe::{ inspections: 0, }
    let orchestrator = @orchestration.BoardOrchestrator(
      owner~,
      resolver~,
      policy=@orchestration.ExecutionPolicy(enabled=true),
    )
    let before = backend.state().unwrap()
    match orchestrator.dispatch_next() {
      Ok(@orchestration.StalePlan(plan)) => {
        assert_eq(plan.revision, before.revision)
        assert_true(plan.eligible.is_empty())
        assert_true(
          plan.blocked[0].reasons.contains(@orchestration.AuthorizationDenied),
        )
      }
      _ => fail("last-line owner rejection must be mapped to fresh plan")
    }
    assert_eq(resolver.inspections, 4)
    assert_eq(journal.writes, 0)
    assert_eq(adapter.calls, 0)
    assert_true(owner.bindings().is_empty())
    assert_eq(backend.state().unwrap(), before)
    assert_true(orchestrator.shutdown())
    backend.shutdown()
  })
}
