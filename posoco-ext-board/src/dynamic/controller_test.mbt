///|
async test "dynamic expansion defaults denied and workflow specs cannot relax absolute budgets" {
  assert_false(
    @dynamic.DynamicWorkflowSpec(
      workflow_id="w",
      initial_scope=[],
      max_executions=1,
      max_elapsed_ms=1000,
      execution_timeout_ms=1000,
    ).validate(),
  )
  assert_false(
    @dynamic.DynamicWorkflowSpec(
      workflow_id="w",
      initial_scope=["t"],
      max_executions=1001,
      max_elapsed_ms=1000,
      execution_timeout_ms=1000,
    ).validate(),
  )
  assert_false(
    @dynamic.DynamicWorkflowSpec(
      workflow_id="w",
      initial_scope=["t"],
      max_executions=1,
      max_elapsed_ms=86400001,
      execution_timeout_ms=1000,
    ).validate(),
  )
  @async.with_task_group(group => {
    let h = dynamic_harness(group, enabled=false)
    let before = h.board.state().unwrap()
    assert_eq(h.controller.status().phase, @workflow.Paused)
    assert_eq(h.model.calls, 0)
    assert_eq(
      h.controller.prepare_proposal(
        payload=dynamic_payload(before.revision),
        authorization_id="a",
        workflow_parent="parent",
        deadline_ms=50000L,
      ),
      Err(@dynamic.ExpansionDisabled),
    )
    assert_eq(h.board.state().unwrap(), before)
    assert_true(
      @dynamic.DynamicWorkflowController::create(
        owner=h.owner,
        backend=@backend.BoardBackend(),
        resolver=h.resolver,
        group~,
        spec=@dynamic.DynamicWorkflowSpec(
          workflow_id="another",
          initial_scope=["parent"],
          max_executions=1,
          max_elapsed_ms=1000,
          execution_timeout_ms=1000,
        ),
      )
      is Err(@dynamic.BackendMismatch),
    )
    dynamic_close(h)
  })
}

///|
async test "committed graph needs exact separate scope approval and detached union preserves initial scope" {
  @async.with_task_group(group => {
    let h = dynamic_harness(group)
    let ids = dynamic_commit(h, chain=true)
    let before = h.board.state().unwrap()
    assert_eq(
      dynamic_authorize(h, ids, grant=false),
      Err(@dynamic.ApprovalDenied),
    )
    assert_eq(h.controller.status().scope, ["parent"])
    assert_eq(h.board.state().unwrap(), before)
    assert_true(
      h.controller.authorize_scope_extension(
        workflow_id="wrong",
        expansion_id="proposal",
        approved_task_ids=ids,
        expected_revision=before.revision,
        approver=ScopeDecision(grant=true),
      )
      is Err(@dynamic.WorkflowMismatch),
    )
    assert_eq(dynamic_authorize(h, [ids[0]]), Err(@dynamic.InvalidScope))
    assert_eq(
      dynamic_authorize(h, [ids[0], "unmapped"]),
      Err(@dynamic.InvalidScope),
    )
    assert_eq(
      dynamic_authorize(h, [ids[0], ids[0]]),
      Err(@dynamic.InvalidScope),
    )
    assert_true(
      h.controller.authorize_scope_extension(
        workflow_id="workflow",
        expansion_id="proposal",
        approved_task_ids=ids,
        expected_revision=before.revision - 1L,
        approver=ScopeDecision(grant=true),
      )
      is Err(@dynamic.StaleRevision),
    )
    ignore(dynamic_authorize(h, ids).unwrap())
    let count = h.controller.status().runner.remaining_executions
    ignore(dynamic_authorize(h, [ids[1], ids[0]]).unwrap())
    assert_eq(h.controller.status().scope_authorizations, 1)
    assert_eq(h.controller.status().runner.remaining_executions, count)
    assert_eq(h.controller.status().scope.length(), 3)
    let view = h.controller.status()
    view.scope.clear()
    ids.clear()
    assert_eq(h.controller.status().scope.length(), 3)
    assert_true(h.controller.status().scope.contains("parent"))
    assert_eq(h.board.state().unwrap(), before)
    dynamic_close(h)
  })
}

///|
async test "default scope policy denies even a granting approver and graph approval denial writes nothing" {
  @async.with_task_group(group => {
    let h = dynamic_harness(group, scope_policy=Denied)
    let ids = dynamic_commit(h)
    assert_eq(dynamic_authorize(h, ids), Err(@dynamic.ScopeApprovalDenied))
    let before = h.board.state().unwrap()
    ignore(
      h.controller
      .prepare_proposal(
        payload=dynamic_payload(before.revision, id="denied"),
        authorization_id="deny-auth",
        workflow_parent="parent",
        deadline_ms=50000L,
      )
      .unwrap(),
    )
    let preview = h.controller.preview().unwrap()
    assert_true(
      h.controller.approve(preview~, approver=GraphDecision(grant=false))
      is Err(@dynamic.ExpansionFailed(@expansion.HostDenied)),
    )
    assert_eq(h.board.state().unwrap(), before)
    assert_eq(h.controller.status().expansion_phase, Some(@expansion.Rejected))
    dynamic_close(h)
  })
}

///|
async test "scope extension validates durable workflow and previously authorized parent lineage" {
  @async.with_task_group(group => {
    let h = dynamic_harness(group)
    let rev = h.board.state().unwrap().revision
    ignore(
      h.board
      .expand_graph(
        expansion=@domain.ExpansionId("foreign"),
        candidates=[
          @domain.GraphTask::from_record(
            id=@domain.BoardTaskId("foreign-child"),
            local_ref="f",
            title="foreign",
            description="",
            priority=@domain.Normal,
            definition_of_done=[],
            dependencies=[],
          ),
        ],
        parent=@domain.BoardTaskId("parent"),
        workflow="foreign-workflow",
        expected_revision=rev,
      )
      .unwrap(),
    )
    assert_eq(
      dynamic_authorize(h, ["foreign-child"], id="foreign"),
      Err(@dynamic.WorkflowMismatch),
    )
    let ids = dynamic_commit(h, id="first")
    let revision = h.board.state().unwrap().revision
    ignore(
      h.board
      .expand_graph(
        expansion=@domain.ExpansionId("recursive"),
        candidates=[
          @domain.GraphTask::from_record(
            id=@domain.BoardTaskId("grandchild"),
            local_ref="g",
            title="grandchild",
            description="",
            priority=@domain.Normal,
            definition_of_done=[],
            dependencies=[],
          ),
        ],
        parent=@domain.BoardTaskId(ids[0]),
        workflow="workflow",
        expected_revision=revision,
      )
      .unwrap(),
    )
    assert_eq(
      dynamic_authorize(h, ["grandchild"], id="recursive"),
      Err(@dynamic.ParentOutOfScope),
    )
    assert_eq(h.controller.status().scope, ["parent"])
    dynamic_close(h)
  })
}

///|
struct PauseGraphApprover {
  controller : @dynamic.DynamicWorkflowController
}

///|
impl @expansion.ExpansionApprover for PauseGraphApprover with fn approve(
  self,
  _,
) {
  ignore(self.controller.pause())
  @expansion.Grant
}

///|
struct CancelScopeApprover {
  controller : @dynamic.DynamicWorkflowController
}

///|
impl @dynamic.ScopeExtensionApprover for CancelScopeApprover with fn approve(
  self,
  _,
) {
  self.controller.cancel()
  @expansion.Grant
}

///|
async test "reentrant pause and cancel cannot turn a stale host decision into scope or graph authority" {
  @async.with_task_group(group => {
    let h = dynamic_harness(group)
    let before = h.board.state().unwrap()
    ignore(
      h.controller
      .prepare_proposal(
        payload=dynamic_payload(before.revision),
        authorization_id="pause-auth",
        workflow_parent="parent",
        deadline_ms=50000L,
      )
      .unwrap(),
    )
    let preview = h.controller.preview().unwrap()
    assert_true(
      h.controller.approve(
        preview~,
        approver=({ controller: h.controller, } : PauseGraphApprover),
      )
      is Err(@dynamic.HostPaused),
    )
    assert_eq(h.board.state().unwrap(), before)
    assert_eq(h.controller.run_wave(), Err(@dynamic.HostPaused))
    ignore(h.controller.resume_workflow().unwrap())
    let ids = dynamic_commit(h, id="after-pause")
    assert_true(
      h.controller.authorize_scope_extension(
        workflow_id="workflow",
        expansion_id="after-pause",
        approved_task_ids=ids,
        expected_revision=h.board.state().unwrap().revision,
        approver=({ controller: h.controller, } : CancelScopeApprover),
      )
      is Err(_),
    )
    assert_eq(h.controller.status().scope, ["parent"])
    assert_false(h.controller.status().scope.contains(ids[0]))
    dynamic_close(h)
  })
}

///|
async test "deadline pause cancellation and expansion reservations never replenish budgets" {
  @async.with_task_group(group => {
    let h = dynamic_harness(group, max_expansions=1)
    let ids = dynamic_commit(h)
    ignore(dynamic_authorize(h, ids).unwrap())
    assert_eq(h.controller.status().remaining_expansions, 0)
    assert_eq(
      h.controller.prepare_proposal(
        payload=dynamic_payload(h.board.state().unwrap().revision, id="over"),
        authorization_id="over-auth",
        workflow_parent="parent",
        deadline_ms=50000L,
      ),
      Err(@dynamic.BudgetExceeded),
    )
    assert_true(h.controller.pause())
    assert_eq(dynamic_authorize(h, ids), Err(@dynamic.HostPaused))
    h.clock.val = 60100L
    assert_true(h.controller.resume_workflow() is Err(_))
    assert_eq(h.controller.status().runner.remaining_ms, 0L)
    assert_true(dynamic_authorize(h, ids) is Err(_))
    h.controller.cancel()
    assert_eq(dynamic_authorize(h, ids), Err(@dynamic.Closed))
    dynamic_close(h)
  })
}

///|
async test "fresh resolver denial blocks generated work without implicit task or review completion" {
  @async.with_task_group(group => {
    let h = dynamic_harness(group)
    let ids = dynamic_commit(h)
    ignore(dynamic_authorize(h, ids).unwrap())
    ignore(
      h.controller
      .prepare_task(
        task_id=ids[0],
        attempt_id="execute",
        expected_revision=h.board.state().unwrap().revision,
      )
      .unwrap(),
    )
    h.resolver.denied = true
    ignore(h.controller.run_wave().unwrap())
    let status = h.controller.wait_boundary().unwrap()
    assert_eq(h.model.calls, 0)
    assert_eq(status.runner.admitted, 0)
    assert_true(
      status.blocked.any(r => {
        r.task_id == ids[0] &&
        r.reasons.contains(@orchestration.AuthorizationDenied)
      }),
    )
    let snapshot = h.board.state().unwrap()
    assert_eq(
      snapshot.tasks.filter(t => t.id.value == ids[0])[0].stage,
      @domain.Ready,
    )
    assert_eq(snapshot.attempts[0].status, @domain.Queued)
    assert_false(snapshot.attempts.any(a => a.kind is @domain.Review))
    dynamic_close(h)
  })
}

///|
async test "shutdown revokes read-only recovery operation admission as well as execution" {
  @async.with_task_group(group => {
    let h = dynamic_harness(group)
    dynamic_close(h)
    assert_eq(h.controller.reconcile(), Err(@dynamic.Closed))
    assert_eq(
      h.controller.reconcile_preparation(task_id="parent"),
      Err(@dynamic.Closed),
    )
    assert_false(h.controller.status().operation_active)
    assert_true(h.controller.shutdown())
  })
}
