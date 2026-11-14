///|
async test "fresh controller never reconstructs execution authority from graph history before or after prior scope approval" {
  @async.with_task_group(group => {
    for approved in [false, true] {
      let storage = @store.MemoryBoardStore()
      let h = dynamic_harness(group, board_store=storage)
      let ids = dynamic_commit(h)
      if approved {
        ignore(dynamic_authorize(h, ids).unwrap())
      }
      let committed = h.board.state().unwrap()
      dynamic_close(h)
      // New process-equivalent composition: only persisted Board/journal data
      // survives, not controller scope grants. No automatic start is requested.
      let board = @backend.BoardBackend(store=storage, now_ms=() => 100L)
      board.attach(group)
      assert_true(board.bootstrap_snapshot() is Ok(_))
      let owner = @execution.BoardExecutionOwner(
        backend=board,
        adapter=@execution.PosocoBoardExecutionAdapter(extensions=() => {
          [h.model]
        }),
        store=h.journal,
      )
      ignore(owner.attach(group).unwrap())
      let controller = @dynamic.DynamicWorkflowController::create(
        owner~,
        backend=board,
        resolver=h.resolver,
        group~,
        spec=@dynamic.DynamicWorkflowSpec(
          workflow_id="workflow",
          initial_scope=["parent"],
          max_executions=3,
          max_elapsed_ms=10000,
          execution_timeout_ms=1000,
          expansion=Some(
            @dynamic.DynamicExpansionSpec(
              max_expansions=4,
              max_generated_tasks=20,
              max_depth=16,
              scope_approval=HostApprover,
            ),
          ),
        ),
      ).unwrap()
      assert_eq(controller.status().phase, @workflow.Idle)
      assert_true(controller.status().scope.is_empty())
      assert_eq(h.model.calls, 0)
      assert_eq(board.state().unwrap(), committed)
      // Even a new explicit start authorizes only its fresh initial scope.
      ignore(controller.start().unwrap())
      assert_eq(controller.status().scope, ["parent"])
      assert_eq(controller.status().scope_authorizations, 0)
      assert_eq(controller.status().expansions_committed, 1)
      assert_eq(
        controller.prepare_task(
          task_id=ids[0],
          attempt_id="after-restart",
          expected_revision=committed.revision,
        ),
        Err(@dynamic.TaskOutOfScope),
      )
      assert_eq(h.model.calls, 0)
      assert_true(controller.shutdown())
    }
  })
}
