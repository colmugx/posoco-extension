///|
/// White-box tests for the GoalRunner port views and lifecycle.
/// (Execute-loop behavior is covered by gate_loop_wbtest / composition_wbtest.)

///|
/// A plan-tool ToolCall carrying the given arguments.
fn plan_call(arguments : Json) -> @posoco.ToolCall {
  @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("c1"),
    name: @posoco.ToolName::unchecked("goal_update_plan"),
    arguments,
  }
}

///|
test "observer_accumulates_usage" {
  let goal = goal_extension(goal_condition="test goal")
  assert_eq(goal.usage.total_tokens, 0)
  assert_eq(goal.usage.turns, 0)

  goal.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=@posoco.Message::AssistantMessage(
        content=[@posoco.Content::Text("hi")],
        tool_calls=[],
        reasoning=None,
        finish_reason=@posoco.FinishReason::Stop,
      ),
      usage=Some({
        input_tokens: Some(100),
        output_tokens: Some(50),
        total_tokens: Some(150),
        cached_input_tokens: None,
        uncached_input_tokens: None,
      }),
    ),
  )
  assert_eq(goal.usage.total_tokens, 150)

  goal.on_event(@posoco.TurnEvent::TurnCompleted)
  assert_eq(goal.usage.turns, 1)
}

///|
test "observer_tracks_tool_repetition" {
  let goal = goal_extension(goal_condition="test goal")
  assert_eq(goal.repeat_count, 0)

  let call = plan_call(Json::null())
  goal.on_event(@posoco.TurnEvent::ToolCallPending(call))
  assert_eq(goal.repeat_count, 1)

  goal.on_event(@posoco.TurnEvent::ToolCallPending(call))
  assert_eq(goal.repeat_count, 2)
}

///|
test "pause_and_resume" {
  let goal = goal_extension(goal_condition="test")
  goal.status = Running
  assert_true(goal.status() == Running)

  goal.pause()
  match goal.status() {
    Paused => ()
    other => fail("expected Paused, got \{other}")
  }

  goal.resume_goal()
  match goal.status() {
    Running => ()
    other => fail("expected Running, got \{other}")
  }
}

///|
test "goal_clear_resets_state" {
  let goal = goal_extension(goal_condition="test")
  goal.status = Running
  goal.usage.turns = 5
  goal.usage.total_tokens = 1000
  goal.current_turn = 3
  goal.charter = "stale charter"
  goal.verifying = true
  goal.last_stall_reason = Some("old reason")

  goal.clear()

  match goal.status() {
    Idle => ()
    other => fail("expected Idle, got \{other}")
  }
  assert_eq(goal.usage.turns, 0)
  assert_eq(goal.usage.total_tokens, 0)
  assert_eq(goal.current_turn, 0)
  assert_eq(goal.charter, "")
  assert_false(goal.verifying)
  assert_eq(goal.plan.items.length(), 0)
  match goal.last_stall_reason {
    None => ()
    Some(_) => fail("last_stall_reason should be None after clear")
  }
}

///|
async test "goal_runner_plan_accessor" {
  let goal = goal_extension(goal_condition="plan accessor")
  let args = Json::object(
    Map::from_array([
      (
        "items",
        Json::array([
          Json::object(
            Map::from_array([
              ("title", Json::string("write code")),
              ("status", Json::string("in_progress")),
            ]),
          ),
          Json::object(
            Map::from_array([
              ("title", Json::string("write tests")),
              ("status", Json::string("pending")),
            ]),
          ),
        ]),
      ),
    ]),
  )

  match
    @posoco.ToolProvider::execute(goal, "goal_update_plan", plan_call(args)) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("0/2"))
    _ => fail("expected Success")
  }

  let plan = goal.plan()
  assert_eq(plan.items.length(), 2)
  assert_eq(plan.items[0].status, InProgress)
  assert_eq(plan.items[1].status, Pending)
}

///|
async test "tool_rejects_bad_args" {
  let goal = goal_extension(goal_condition="bad args")
  let call = plan_call(Json::string("not an object"))

  match @posoco.ToolProvider::execute(goal, "goal_update_plan", call) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.length() > 0)
    _ => fail("expected ToolReportedError")
  }
}

///|
async test "tool_unknown_name" {
  let goal = goal_extension(goal_condition="unknown")
  let call = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("c1"),
    name: @posoco.ToolName::unchecked("other_tool"),
    arguments: Json::null(),
  }

  match @posoco.ToolProvider::execute(goal, "other_tool", call) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_eq(content, "unknown tool")
    _ => fail("expected ToolReportedError")
  }
}

///|
test "charter_while_idle_is_empty" {
  let goal = goal_extension(goal_condition="idle")
  assert_eq(goal.system_prompt(), "")
}
