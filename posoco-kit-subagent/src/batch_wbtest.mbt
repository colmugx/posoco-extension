///|
fn batch_item(key~ : String, timeout_ms? : Int = 60000) -> BatchItem {
  {
    key,
    child_session_id: key,
    task: "do \{key}",
    kind_name: "coder",
    selection: { slot: "main", effort: None, },
    tools: ["read"],
    permission: @permission.PermissionMode::Interactive,
    mode: @posoco.TaskMode::Background,
    timeout_ms,
    resuming: false,
  }
}

///|
fn batch_receipt(id~ : String, label? : String = "") -> @posoco.TaskReceipt {
  {
    id,
    session_id: "parent-session",
    mode: @posoco.TaskMode::Background,
    label,
    extension_id: "posoco_ext_subagent",
  }
}

///|
test "batch/plan_build_validates_and_derives_wave_cap" {
  let config = SubagentConfig::defaults()
  let plan = BatchPlan::build(config~, items=[
    batch_item(key="a"),
    batch_item(key="b"),
  ])
  assert_eq(plan.items.length(), 2)
  assert_eq(plan.wave_cap, config.limits.concurrency)
  try BatchPlan::build(config~, items=[]) catch {
    error => assert_eq(error, BatchPlanError::ItemsEmpty)
  } noraise {
    _plan => fail("expected empty batch to be refused")
  }
  let too_many : Array[BatchItem] = []
  for i = 0; i < config.limits.swarm_items + 1; i = i + 1 {
    too_many.push(batch_item(key="item-\{i}"))
  }
  try BatchPlan::build(config~, items=too_many) catch {
    error =>
      assert_eq(
        error,
        BatchPlanError::TooManyItems(limit=config.limits.swarm_items),
      )
  } noraise {
    _plan => fail("expected oversized batch to be refused")
  }
  try
    BatchPlan::build(config~, items=[batch_item(key="a"), batch_item(key="a")])
  catch {
    error => assert_eq(error, BatchPlanError::DuplicateKey(key="a"))
  } noraise {
    _plan => fail("expected duplicate key to be refused")
  }
  try
    BatchPlan::build(config~, items=[batch_item(key="a", timeout_ms=0)])
  catch {
    error => assert_eq(error, BatchPlanError::InvalidTimeout(key="a"))
  } noraise {
    _plan => fail("expected zero timeout to be refused")
  }
  let clamped = { ..config, limits: { ..config.limits, concurrency: 0, }, }
  assert_eq(
    BatchPlan::build(config=clamped, items=[batch_item(key="a")]).wave_cap,
    1,
  )
}

///|
test "batch/state_tracks_acceptance_and_terminals" {
  let plan = BatchPlan::build(config=SubagentConfig::defaults(), items=[
    batch_item(key="a"),
    batch_item(key="b"),
  ])
  let state = BatchState::BatchState(plan~)
  assert_false(state.is_settled())
  state.on_accepted(key="a", receipt=batch_receipt(id="r1"))
  state.on_accepted(key="b", receipt=batch_receipt(id="r2"))
  state.on_outcome(outcome={
    receipt: batch_receipt(id="r1"),
    status: @posoco.TaskStatus::Completed(
      message=@posoco.Message::UserMessage(content=[
        @posoco.Content::Text("done"),
      ]),
    ),
  })
  assert_false(state.is_settled())
  assert_eq(state.pending, ["b"])
  state.on_outcome(outcome={
    receipt: batch_receipt(id="r2"),
    status: @posoco.TaskStatus::TimedOut,
  })
  assert_true(state.is_settled())
  // Unknown receipt ids are ignored, and repeated outcomes stay idempotent.
  state.on_outcome(outcome={
    receipt: batch_receipt(id="unknown"),
    status: @posoco.TaskStatus::Cancelled(reason="scope shutdown"),
  })
  state.on_outcome(outcome={
    receipt: batch_receipt(id="r1"),
    status: @posoco.TaskStatus::Failed(reason="replayed"),
  })
  assert_true(state.is_settled())
  let result = state.result()
  assert_eq(result.completed, 1)
  assert_eq(result.timed_out, 1)
  assert_eq(result.failed, 0)
  assert_eq(result.cancelled, 0)
  assert_eq(result.terminals["a"], TerminalState::Completed)
  assert_eq(result.terminals["b"], TerminalState::TimedOut)
}

///|
test "batch/status_mapping_and_words" {
  assert_eq(
    task_status_to_terminal(
      status=@posoco.TaskStatus::Completed(
        message=@posoco.Message::UserMessage(content=[
          @posoco.Content::Text("done"),
        ]),
      ),
    ),
    TerminalState::Completed,
  )
  assert_eq(
    task_status_to_terminal(status=@posoco.TaskStatus::Failed(reason="boom")),
    TerminalState::Failed(reason="boom"),
  )
  assert_eq(
    task_status_to_terminal(status=@posoco.TaskStatus::TimedOut),
    TerminalState::TimedOut,
  )
  assert_eq(
    task_status_to_terminal(
      status=@posoco.TaskStatus::Cancelled(reason="host abort"),
    ),
    TerminalState::Cancelled,
  )
  assert_eq(terminal_state_word(TerminalState::Completed), "completed")
  assert_eq(terminal_state_word(TerminalState::Failed(reason="boom")), "failed")
  assert_eq(terminal_state_word(TerminalState::TimedOut), "timed_out")
  assert_eq(terminal_state_word(TerminalState::Cancelled), "cancelled")
}

///|
test "batch/result_summary_lines" {
  let result : BatchResult = {
    terminals: Map::from_array([
      ("a", TerminalState::Completed),
      ("b", TerminalState::Failed(reason="boom")),
      ("c", TerminalState::TimedOut),
      ("d", TerminalState::Cancelled),
    ]),
    completed: 1,
    failed: 1,
    timed_out: 1,
    cancelled: 1,
  }
  let text = result.summary()
  assert_true(text.contains("a: completed"))
  assert_true(text.contains("b: failed: boom"))
  assert_true(text.contains("c: timed out"))
  assert_true(text.contains("d: cancelled"))
  assert_true(
    text.contains("total: 1 completed, 1 failed, 1 timed out, 1 cancelled"),
  )
}
