///|
async fn dynamic_until(check : () -> Bool) -> Unit {
  @async.with_timeout(2000, () => {
    while !check() {
      @async.sleep(1)
    }
  })
}

///|
async test "two active executions keep exact identities while proposals wait and planning admission is denied" {
  @async.with_task_group(group => {
    let h = dynamic_harness(group)
    let ids = dynamic_commit(h, id="initial")
    ignore(dynamic_authorize(h, ids, id="initial").unwrap())
    ignore(
      h.controller
      .prepare_task(
        task_id=ids[0],
        attempt_id="child",
        expected_revision=h.board.state().unwrap().revision,
      )
      .unwrap(),
    )
    dynamic_move(h, "parent", @domain.Refining)
    dynamic_move(h, "parent", @domain.Ready)
    dynamic_queue(h, "parent", "parent-exec")
    dynamic_queue(h, "parent", "future-planning")
    h.model.delay = 80
    ignore(h.controller.run_wave().unwrap())
    dynamic_until(() => h.model.active == 2)
    let active = h.owner.status().active_bindings
    let budget = h.controller.status().runner.remaining_executions
    assert_eq(active.length(), 2)
    assert_eq(
      h.controller.generate_plan(
        request={
          task_id: "parent",
          attempt_id: "future-planning",
          execution_id: "next-plan",
          session_id: "next-session",
          input: "trusted plan",
          timeout_ms: Some(1000),
        },
        channel=h.channel,
        authorization_id="during-active",
        workflow_parent="parent",
        deadline_ms=50000L,
      ),
      Err(@dynamic.NotQuiescent),
    )
    assert_eq(h.controller.status().runner.remaining_executions, budget)
    let revision = h.board.state().unwrap().revision
    ignore(
      h.controller
      .prepare_proposal(
        payload=dynamic_payload(revision, id="during-wave"),
        authorization_id="wave-auth",
        workflow_parent="parent",
        deadline_ms=50000L,
      )
      .unwrap(),
    )
    let preview = h.controller.preview().unwrap()
    let approval = h.controller
      .approve(preview~, approver=GraphDecision(grant=true))
      .unwrap()
    assert_eq(h.controller.commit(approval~), Err(@dynamic.NotQuiescent))
    assert_true(h.owner.status().active_bindings.all(b => active.contains(b)))
    assert_eq(h.controller.status().scope.length(), 2)
    ignore(h.controller.wait_boundary().unwrap())
    h.channel.discard()
    assert_true(
      h.controller.commit(approval~)
      is Err(@dynamic.ExpansionFailed(@expansion.StalePreview)),
    )
    assert_eq(h.board.expansion_history().unwrap().length(), 1)
    assert_eq(h.model.calls, 2)
    for binding in h.owner.bindings() {
      assert_eq(binding.phase, @execution.Settled)
      assert_eq(binding.outcome, Some(@execution.Completed))
      assert_true(
        active.any(b => {
          b.execution_id == binding.execution_id &&
          b.attempt_id == binding.attempt_id &&
          b.session_id == binding.session_id &&
          b.run == binding.run
        }),
      )
    }
    dynamic_close(h)
  })
}

///|
async test "parent edits during an actual planning turn invalidate the emitted revision without graph effects" {
  @async.with_task_group(group => {
    let h = dynamic_harness(group)
    dynamic_queue(h, "parent", "planning")
    let revision = h.board.state().unwrap().revision
    h.model.payload = dynamic_payload(revision + 2L)
    h.model.delay = 50
    let planning = group.spawn(() => {
      h.controller.generate_plan(
        request={
          task_id: "parent",
          attempt_id: "planning",
          execution_id: "plan",
          session_id: "session-plan",
          input: "trusted requirements",
          timeout_ms: Some(1000),
        },
        channel=h.channel,
        authorization_id="edit-auth",
        workflow_parent="parent",
        deadline_ms=50000L,
      )
    })
    dynamic_until(() => h.model.active == 1)
    let now = h.board.state().unwrap().revision
    ignore(
      h.board
      .submit(
        @domain.UpdateTask(
          id=@domain.BoardTaskId("parent"),
          title=Some("Operator changed parent"),
          description=None,
          priority=None,
          definition_of_done=None,
          user_story=None,
          implementation_suggestions=None,
          at_ms=h.clock.val,
          expected_revision=now,
        ),
      )
      .unwrap(),
    )
    assert_true(
      planning.wait() is Err(@dynamic.ExpansionFailed(@expansion.StalePreview)),
    )
    assert_eq(h.board.expansion_history().unwrap().length(), 0)
    assert_eq(h.controller.status().runner.settled, 1)
    dynamic_close(h)
  })
}

///|
async test "cancellation joins the exact owned planning run and preserves its charged budget" {
  @async.with_task_group(group => {
    let h = dynamic_harness(group)
    dynamic_queue(h, "parent", "planning")
    h.model.payload = dynamic_payload(h.board.state().unwrap().revision + 2L)
    h.model.delay = 500
    let planning = group.spawn(() => {
      h.controller.generate_plan(
        request={
          task_id: "parent",
          attempt_id: "planning",
          execution_id: "cancel-plan",
          session_id: "cancel-session",
          input: "trusted requirements",
          timeout_ms: Some(1000),
        },
        channel=h.channel,
        authorization_id="cancel-auth",
        workflow_parent="parent",
        deadline_ms=50000L,
      )
    })
    dynamic_until(() => h.model.active == 1)
    h.controller.cancel()
    assert_true(planning.wait() is Err(_))
    let status = h.controller.status()
    assert_false(status.planning_active)
    assert_eq(status.runner.remaining_executions, 7)
    assert_eq(status.runner.cancelled, 1)
    assert_eq(h.model.active, 0)
    assert_true(h.owner.status().active_bindings.is_empty())
    let binding = h.owner.bindings()[0]
    assert_eq(binding.execution_id, "cancel-plan")
    assert_eq(binding.phase, @execution.Settled)
    assert_eq(binding.outcome, Some(@execution.Cancelled))
    assert_eq(h.channel.take(binding), None)
    assert_eq(h.board.expansion_history().unwrap().length(), 0)
    dynamic_close(h)
  })
}

///|
struct FailingExecutionJournal {
  inner : @execution.MemoryBoardExecutionStore
}

///|
impl @execution.BoardExecutionStore for FailingExecutionJournal with fn load(
  self,
) {
  self.inner.load()
}

///|
impl @execution.BoardExecutionStore for FailingExecutionJournal with fn persist(
  self,
  records,
) {
  if records.any(b => b.phase is @execution.Finished) {
    return Err(@execution.StoreUnavailable)
  }
  self.inner.persist(records)
}

///|
async test "unresolved owned execution blocks shutdown and cannot cross-settle another Attempt" {
  @async.with_task_group(group => {
    let journal = { inner: @execution.MemoryBoardExecutionStore(), }
    let h = dynamic_harness(group, execution_store=Some(journal))
    let ids = dynamic_commit(h)
    ignore(dynamic_authorize(h, ids).unwrap())
    ignore(
      h.controller
      .prepare_task(
        task_id=ids[0],
        attempt_id="unresolved",
        expected_revision=h.board.state().unwrap().revision,
      )
      .unwrap(),
    )
    ignore(h.controller.run_wave().unwrap())
    let status = h.controller.wait_boundary().unwrap()
    assert_eq(status.phase, @workflow.Unresolved)
    assert_true(status.unresolved)
    assert_eq(h.owner.bindings().length(), 1)
    assert_eq(h.owner.bindings()[0].attempt_id, "unresolved")
    assert_false(h.controller.shutdown(timeout_ms=50))
    assert_true(h.board.state() is Ok(_))
    // Isolated memory fixture teardown: no physical lock is released and no
    // active provider remains. Production host must retain ownership here.
    assert_eq(h.model.active, 0)
    h.board.shutdown()
  })
}

///|
async test "boundary wait does not mistake a paused runner for a joined planning operation" {
  @async.with_task_group(group => {
    let h = dynamic_harness(group)
    dynamic_queue(h, "parent", "planning")
    h.model.payload = dynamic_payload(h.board.state().unwrap().revision + 2L)
    h.model.delay = 80
    let planning = group.spawn(() => {
      h.controller.generate_plan(
        request={
          task_id: "parent",
          attempt_id: "planning",
          execution_id: "waiting-plan",
          session_id: "waiting-session",
          input: "trusted input",
          timeout_ms: Some(1000),
        },
        channel=h.channel,
        authorization_id="waiting-auth",
        workflow_parent="parent",
        deadline_ms=50000L,
      )
    })
    dynamic_until(() => h.model.active == 1)
    let boundary = group.spawn(() => h.controller.wait_boundary())
    @async.sleep(5)
    assert_true(boundary.try_wait() is None)
    ignore(planning.wait().unwrap())
    let status = boundary.wait().unwrap()
    assert_false(status.planning_active)
    assert_false(status.operation_active)
    assert_eq(status.runner.settled, 1)
    dynamic_close(h)
  })
}
