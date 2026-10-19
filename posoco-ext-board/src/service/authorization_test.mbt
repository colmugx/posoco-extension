///|
/// Cross-target proof that a refused workflow performed no durable IO at all:
/// the read-only journal inspection stays empty and a fresh store can still
/// acquire the identity lock that no workflow ever created.
async fn assert_no_storage_io(directory : String) -> Unit {
  assert_eq(
    @journal.FileBoardExecutionStore::inspect(directory~).checked().length(),
    0,
  )
  let probe = @journal.FileBoardExecutionStore(directory~)
  assert_true(probe.load() is Ok(_))
  probe.close()
}

///|
/// The live authorization gate is consulted per operation, before any prompt
/// or storage effect. Denial gates mutation only; detached observation and
/// teardown stay available.
async test "denied live authorization blocks start and resume without any IO" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group, authorize=() => false)
    defer ignore(h.board.shutdown())
    assert_eq(
      h.board.start(title="Live gate denied"),
      Err(@service.ApprovalDenied),
    )
    assert_eq(h.board.resume_workflow(), Err(@service.ApprovalDenied))
    assert_eq(h.board.view().checked().snapshot.tasks.length(), 0)
    assert_false(h.board.view().checked().unresolved)
    assert_true(h.state.contexts.is_empty())
    assert_true(h.ui.prompts.is_empty())
    assert_no_storage_io(directory)
  })
}

///|
/// A Yes answer alone never authorizes: the gate is rechecked after the UI
/// responds, so a revocation during the approval window refuses the mutation
/// and nothing from the refused approval carries into later operations.
async test "revoking live authorization during an answered approval still refuses the mutation" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let gate = Ref(true)
    let h = harness(directory, group, authorize=() => gate.val)
    defer ignore(h.board.shutdown())
    let started = h.board.start(title="Live gate revocation").checked()
    ignore(
      h.board
      .propose(
        parent=started.run.checked().scope[0],
        requirements="trusted planning requirements",
      )
      .checked(),
    )
    assert_eq(h.ui.prompts.length(), 2)
    let durable = h.board.view().checked().snapshot.revision
    h.ui.before_answer = Some(() => gate.val = false)
    assert_eq(h.board.graph_decision(grant=true), Err(@service.ApprovalDenied))
    let refused = h.board.view().checked()
    assert_true(refused.snapshot.expansions.is_empty())
    assert_eq(refused.snapshot.tasks.length(), 1)
    assert_eq(refused.snapshot.revision, durable)
    assert_eq(refused.run.checked().scope.length(), 1)
    assert_false(refused.mutation_uncertain)
    assert_eq(h.ui.prompts.length(), 3)
    assert_true(h.ui.prompts[2].has_prefix("GRAPH APPROVAL"))
    gate.val = true
    h.ui.before_answer = None
    let committed = h.board.graph_decision(grant=true).checked()
    assert_eq(committed.snapshot.tasks.length(), 3)
    assert_eq(h.ui.prompts.length(), 4)
    h.ui.before_answer = Some(() => gate.val = false)
    let expansion = committed.snapshot.expansions[0].expansion_id.value
    assert_eq(
      h.board.scope_decision(expansion_id=expansion, grant=true),
      Err(@service.ApprovalDenied),
    )
    let held = h.board.view().checked()
    assert_eq(held.run.checked().scope.length(), 1)
    let generated = committed.snapshot.expansions[0].mapping.map(m => {
      m.task_id.value
    })
    assert_false(
      held.snapshot.attempts.any(a => generated.contains(a.task_id.value)),
    )
    assert_true(held.executions.all(e => e.phase == @execution.Settled))
    assert_eq(h.ui.prompts.length(), 5)
    assert_true(h.ui.prompts[4].has_prefix("EXECUTION SCOPE APPROVAL"))
  })
}

///|
/// Each explicit approval authorizes exactly one effect. A consumed graph
/// approval cannot be replayed into a second commit, and it never carried
/// execution-scope authority: that gate keeps requiring its own fresh Yes.
async test "one explicit approval never coalesces into the other gate or replays" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group)
    defer ignore(h.board.shutdown())
    let started = h.board.start(title="Separate approvals").checked()
    ignore(
      h.board
      .propose(
        parent=started.run.checked().scope[0],
        requirements="trusted planning requirements",
      )
      .checked(),
    )
    let committed = h.board.graph_decision(grant=true).checked()
    let expansion = committed.snapshot.expansions[0].expansion_id.value
    let task = committed.snapshot.expansions[0].mapping[0].task_id.value
    assert_eq(committed.snapshot.expansions.length(), 1)
    assert_eq(committed.snapshot.tasks.length(), 3)
    assert_eq(committed.run.checked().scope.length(), 1)
    let before = h.board.view().checked()
    assert_eq(h.board.graph_decision(grant=true), Err(@service.InvalidProposal))
    let after = h.board.view().checked()
    assert_eq(after.snapshot.expansions.length(), 1)
    assert_eq(after.snapshot.revision, before.snapshot.revision)
    assert_eq(after.run.checked().scope.length(), 1)
    assert_eq(
      h.ui.prompts.filter(p => p.has_prefix("GRAPH APPROVAL")).length(),
      1,
    )
    assert_true(
      h.board.prepare(task_id=task, input="trusted execution input")
      is Err(@service.OperationRejected),
    )
    assert_true(
      h.board.scope_decision(expansion_id=expansion, grant=false)
      is Err(@service.ApprovalDenied),
    )
    assert_eq(
      h.ui.prompts
      .filter(p => p.has_prefix("EXECUTION SCOPE APPROVAL"))
      .length(),
      0,
    )
    let extended = h.board
      .scope_decision(expansion_id=expansion, grant=true)
      .checked()
    assert_eq(extended.run.checked().scope.length(), 3)
    assert_eq(
      h.ui.prompts
      .filter(p => p.has_prefix("EXECUTION SCOPE APPROVAL"))
      .length(),
      1,
    )
  })
}
