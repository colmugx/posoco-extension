///|
async test "actual owned Agent proposal becomes separately authorized generated execution under shared budgets" {
  @async.with_task_group(group => {
    let h = dynamic_harness(group, max_executions=4)
    dynamic_move(h, "parent", @domain.Refining)
    dynamic_move(h, "parent", @domain.Ready)
    dynamic_queue(h, "parent", "existing")
    dynamic_queue(h, "parent", "planning")
    let before = h.board.state().unwrap()
    // This deterministic model emits the exact post-planning-settlement revision.
    // Production integration does not rewrite or retry stale model revisions.
    let payload = dynamic_payload(before.revision + 2L, chain=true)
    h.model.payload = payload
    ignore(
      h.controller
      .generate_plan(
        request={
          task_id: "parent",
          attempt_id: "planning",
          execution_id: "plan-exec",
          session_id: "plan-session",
          input: "authorized-planning-requirements",
          timeout_ms: Some(1000),
        },
        channel=h.channel,
        authorization_id="planning-auth",
        workflow_parent="parent",
        deadline_ms=50000L,
      )
      .unwrap(),
    )
    assert_eq(h.model.calls, 1)
    assert_eq(h.controller.status().runner.admitted, 1)
    assert_eq(h.controller.status().runner.settled, 1)
    assert_eq(h.controller.status().runner.remaining_executions, 3)
    assert_eq(h.board.expansion_history().unwrap().length(), 0)
    let preview = h.controller.preview().unwrap()
    let approval = h.controller
      .approve(preview~, approver=GraphDecision(grant=true))
      .unwrap()
    ignore(h.controller.commit(approval~).unwrap())
    let committed = h.board.state().unwrap()
    assert_eq(committed.revision, before.revision + 3L)
    let record = committed.expansions[0]
    let ids = record.mapping.map(p => p.task_id.value)
    assert_eq(ids.length(), 2)
    for id in ids {
      assert_eq(
        committed.tasks.filter(t => t.id.value == id)[0].stage,
        @domain.Created,
      )
      assert_false(committed.attempts.any(a => a.task_id.value == id))
    }
    assert_eq(h.controller.status().scope, ["parent"])
    assert_true(
      h.controller.prepare_task(
        task_id=ids[0],
        attempt_id="a-exec",
        expected_revision=committed.revision,
      )
      is Err(@dynamic.TaskOutOfScope),
    )
    ignore(dynamic_authorize(h, ids).unwrap())
    assert_eq(h.controller.status().runner.remaining_executions, 3)
    let rev_a = h.board.state().unwrap().revision
    ignore(
      h.controller
      .prepare_task(
        task_id=ids[0],
        attempt_id="a-exec",
        expected_revision=rev_a,
      )
      .unwrap(),
    )
    ignore(
      h.controller
      .prepare_task(
        task_id=ids[1],
        attempt_id="b-exec",
        expected_revision=rev_a + 3L,
      )
      .unwrap(),
    )
    h.model.payload = "execution-result"
    h.model.delay = 15
    ignore(h.controller.run_wave().unwrap())
    let settled = h.controller.wait_boundary().unwrap()
    h.channel.discard()
    assert_eq(settled.runner.admitted, 3)
    assert_eq(settled.runner.settled, 3)
    assert_eq(h.model.peak, 2)
    assert_eq(h.owner.bindings().length(), 3)
    let current = h.board.state().unwrap()
    assert_eq(
      current.attempts.filter(a => a.id.value == "a-exec")[0].status,
      @domain.Succeeded,
    )
    assert_eq(
      current.attempts.filter(a => a.id.value == "b-exec")[0].status,
      @domain.Queued,
    )
    assert_eq(
      current.tasks.filter(t => t.id.value == ids[0])[0].stage,
      @domain.Ready,
    )
    assert_true(
      settled.blocked.any(r => {
        r.task_id == ids[1] &&
        r.reasons.contains(@orchestration.DependencyNotDone(ids[0]))
      }),
    )
    assert_false(current.attempts.any(a => a.kind is @domain.Review))
    // Only the operator's separate legal completion path unblocks B.
    dynamic_move(h, ids[0], @domain.Running)
    dynamic_move(h, ids[0], @domain.Review)
    dynamic_move(h, ids[0], @domain.Done)
    ignore(h.controller.run_wave().unwrap())
    let done = h.controller.wait_boundary().unwrap()
    h.channel.discard()
    assert_eq(done.runner.admitted, 4)
    assert_eq(done.runner.settled, 4)
    assert_eq(done.runner.remaining_executions, 0)
    let binding = h.owner.bindings().filter(b => b.attempt_id == "b-exec")[0]
    assert_eq(binding.phase, @execution.Settled)
    assert_eq(binding.outcome, Some(@execution.Completed))
    assert_eq(binding.session_id, "session-b-exec")
    assert_true(binding.run is Some(_))
    let persisted = h.journal.load().unwrap()
    assert_eq(persisted, h.owner.bindings())
    let text = @execution.encode_execution_journal(persisted).unwrap()
    assert_false(text.contains("authorized-planning-requirements"))
    assert_false(text.contains("trusted-host-input"))
    assert_false(text.contains(payload))
    assert_false(text.contains("execution-result"))
    assert_eq(
      h.board
      .event_history()
      .filter(e => e.kind == "board.graph.expanded")
      .length(),
      1,
    )
    dynamic_close(h)
  })
}

///|
async test "actual invalid or failed planning output never mutates the graph" {
  @async.with_task_group(group => {
    let h = dynamic_harness(group)
    dynamic_queue(h, "parent", "invalid-plan")
    h.model.payload = "not a proposal"
    let graph_revision = h.board.state().unwrap().revision
    let result = h.controller.generate_plan(
      request={
        task_id: "parent",
        attempt_id: "invalid-plan",
        execution_id: "invalid-exec",
        session_id: "invalid-session",
        input: "trusted planning",
        timeout_ms: Some(1000),
      },
      channel=h.channel,
      authorization_id="invalid-auth",
      workflow_parent="parent",
      deadline_ms=50000L,
    )
    assert_true(
      result is Err(@dynamic.ExpansionFailed(@expansion.DecodeFailed(_))),
    )
    assert_eq(h.board.state().unwrap().revision, graph_revision + 2L)
    assert_eq(h.board.state().unwrap().tasks.length(), 1)
    assert_eq(h.board.expansion_history().unwrap().length(), 0)
    assert_eq(h.controller.status().runner.remaining_executions, 7)
    dynamic_queue(h, "parent", "failed-plan")
    h.model.fail = true
    assert_true(
      h.controller.generate_plan(
        request={
          task_id: "parent",
          attempt_id: "failed-plan",
          execution_id: "failed-exec",
          session_id: "failed-session",
          input: "trusted planning",
          timeout_ms: Some(1000),
        },
        channel=h.channel,
        authorization_id="failed-auth",
        workflow_parent="parent",
        deadline_ms=50000L,
      )
      is Err(_),
    )
    assert_eq(
      h.owner.bindings().last().unwrap().outcome,
      Some(@execution.Failed),
    )
    assert_eq(h.board.expansion_history().unwrap().length(), 0)
    assert_eq(h.controller.status().runner.failed, 1)
    dynamic_close(h)
  })
}
