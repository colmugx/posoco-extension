///|
async test "control joins a dependency chain with exact evidence and legal stages without Review approval" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group, max_executions=6)
    defer ignore(h.board.shutdown())
    let committed = proposed(h)
    let expansion = committed.snapshot.expansions[0]
    let a = expansion.mapping[0].task_id.value
    let b = expansion.mapping[1].task_id.value
    let scoped = h.board.scope_decision(expansion_id=expansion.expansion_id.value, grant=true).checked()
    let scope = [a, b]
    let allowed = Ref(true)
    let control = h.board.authorize_control(
      workflow_id=scoped.run.checked().workflow_id, task_ids=scope,
      expected_revision=scoped.snapshot.revision, max_runs=2, deadline_ms=10000L,
      authorize=() => allowed.val,
    ).checked()
    scope.clear()
    let prompts = h.ui.prompts.length()
    // Mixing the manual and controlled routes must not consume output, queue
    // duplicate identities, or insert a competing approval operation.
    assert_true(h.board.wait_boundary() is Err(@service.Busy))
    assert_true(h.board.run_wave() is Err(@service.Busy))
    assert_true(h.board.prepare(task_id=a, input="competing input") is Err(@service.Busy))
    assert_true(h.board.propose(parent=a, requirements="competing planning") is Err(@service.Busy))
    assert_true(h.board.scope_decision(expansion_id=expansion.expansion_id.value, grant=true) is Err(@service.Busy))
    assert_eq(h.ui.prompts.length(), prompts)
    let attempt_a = control.prepare(task_id=a, input="trusted A input", expected_revision=scoped.snapshot.revision).checked()
    let revision = h.board.view().checked().snapshot.revision
    let attempt_b = control.prepare(task_id=b, input="trusted B input", expected_revision=revision).checked()
    assert_true(attempt_a != attempt_b)
    assert_eq(control.plan().checked().eligible.map(c => c.task_id), [a])
    control.run_wave().checked()
    let outputs = control.take_results().checked()
    assert_eq(outputs.length(), 1)
    assert_eq(outputs[0].binding.attempt_id, attempt_a)
    assert_eq(outputs[0].binding.phase, @execution.Settled)
    assert_eq(outputs[0].binding.outcome, Some(@execution.Completed))
    assert_eq(outputs[0].assistant_text, Some("private actual Agent execution result"))
    assert_eq(control.take_results().checked().length(), 0)
    let snapshot = h.board.view().checked().snapshot
    assert_eq(snapshot.attempts.filter(x => x.id.value == attempt_b)[0].status, @domain.Queued)
    assert_eq(snapshot.tasks.filter(x => x.id.value == a)[0].stage, @domain.Ready)
    assert_true(control.plan().checked().eligible.is_empty())
    assert_true(control.transition(task_id=a, to=@domain.Running,
      expected_revision=snapshot.revision - 1L) is Err(@service.RevisionConflict))
    let mut revision = snapshot.revision
    for stage in ([@domain.Running, @domain.Review, @domain.Done] : Array[@domain.BoardStage]) {
      revision = control.transition(task_id=a, to=stage, expected_revision=revision).checked()
    }
    assert_eq(control.plan().checked().eligible.map(c => c.task_id), [b])
    control.run_wave().checked()
    let outputs = control.take_results().checked()
    assert_eq(outputs.length(), 1)
    assert_eq(outputs[0].binding.attempt_id, attempt_b)
    let snapshot = h.board.view().checked().snapshot
    assert_true(snapshot.attempts.all(a => a.kind != @domain.Review))
    assert_eq(snapshot.tasks.filter(t => t.id.value == b)[0].stage, @domain.Ready)
    assert_eq(h.ui.prompts.length(), prompts)
    allowed.val = false
    assert_true(control.transition(task_id=b, to=@domain.Running,
      expected_revision=snapshot.revision) is Err(@service.Closed))
    control.revoke()
    assert_true(control.run_wave() is Err(@service.Closed))
  })
}

///|
async test "control is default denied duplicate scopes rejected and a revoked lease does not replenish budgets" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group, max_executions=6)
    defer ignore(h.board.shutdown())
    let committed = proposed(h)
    let expansion = committed.snapshot.expansions[0]
    let a = expansion.mapping[0].task_id.value
    let scoped = h.board.scope_decision(expansion_id=expansion.expansion_id.value, grant=true).checked()
    let workflow = scoped.run.checked().workflow_id
    assert_true(h.board.authorize_control(workflow_id=workflow, task_ids=[a],
      expected_revision=scoped.snapshot.revision, max_runs=1, deadline_ms=10000L) is Err(@service.OperationRejected))
    assert_true(h.board.authorize_control(workflow_id=workflow, task_ids=[a, a],
      expected_revision=scoped.snapshot.revision, max_runs=1, deadline_ms=10000L,
      authorize=() => true) is Err(@service.OperationRejected))
    let remaining = scoped.run.checked().runner.remaining_executions
    let control = h.board.authorize_control(workflow_id=workflow, task_ids=[a],
      expected_revision=scoped.snapshot.revision, max_runs=1, deadline_ms=10000L,
      authorize=() => true).checked()
    control.revoke()
    let replacement = h.board.authorize_control(workflow_id=workflow, task_ids=[a],
      expected_revision=scoped.snapshot.revision, max_runs=1, deadline_ms=10000L,
      authorize=() => true).checked()
    control.revoke()
    assert_eq(h.board.view().checked().run.checked().runner.remaining_executions, remaining)
    replacement.revoke()
  })
}
