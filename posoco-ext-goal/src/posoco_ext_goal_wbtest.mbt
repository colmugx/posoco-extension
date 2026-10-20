///|
/// White-box tests for the GoalRunner port views and lifecycle.
/// (Execute-loop behavior is covered by gate_loop_wbtest / composition_wbtest.)

///|
/// Effect context for a plan-tool call (no-op registrar).
fn test_ctx(name : String, arguments : Json) -> @posoco.ToolCallContext {
  {
    effect_id: @kernel.EffectId::{ value: 1, },
    call_id: @posoco.CallId::unchecked("c1"),
    name: @posoco.ToolName::unchecked(name),
    arguments,
    register_cancel: fn(_ : &@posoco.ToolCancellable) { () },
  }
}

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
    @posoco.ToolProvider::execute(goal, test_ctx("goal_update_plan", args)) {
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
  let ctx = test_ctx("goal_update_plan", Json::string("not an object"))

  match @posoco.ToolProvider::execute(goal, ctx) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.length() > 0)
    _ => fail("expected ToolReportedError")
  }
}

///|
async test "tool_unknown_name" {
  let goal = goal_extension(goal_condition="unknown")
  let ctx = test_ctx("other_tool", Json::null())

  match @posoco.ToolProvider::execute(goal, ctx) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_eq(content, "unknown tool")
    _ => fail("expected ToolReportedError")
  }
}

///|
/// Core 0.13.0 owns the static system prompt, so the extension exposes no
/// prompt-contributor surface at all; the charter rides the first working
/// turn's user input instead (delivery asserted at the composition level).
test "charter_not_a_prompt_contributor" {
  let goal = goal_extension(goal_condition="make tests green")
  assert_eq(goal.manifest().prompt_contributors.length(), 0)
}

///|
/// The charter is options-derived and rebuilt at each execute() start;
/// clear() never touches the options and re-arms first-turn delivery.
test "clear_keeps_options_derived_charter" {
  let goal = goal_extension(goal_condition="idle after clear")
  goal.status = Running
  goal.clear()
  assert_eq(goal.options.goal_condition, "idle after clear")
  assert_false(goal.charter_delivered)
}

///|

test "goal default has a bounded turn budget" {
  let goal = goal_extension(goal_condition="bounded by default")
  assert_true(goal.options.budget.max_turns > 0)
}

test "scoped observer rejects foreign sessions and out-of-turn events" {
  let goal = goal_extension(goal_condition="scope")
  goal.status = Running
  goal.active_session_id = Some("s1")
  let usage : @posoco.Usage = {
    input_tokens: Some(6),
    output_tokens: Some(4),
    total_tokens: Some(10),
    cached_input_tokens: None,
    uncached_input_tokens: None,
  }
  let event = @posoco.TurnEvent::ModelResponseReceived(
    message=@posoco.Message::AssistantMessage(
      content=[@posoco.Content::Text("ok")],
      tool_calls=[],
      reasoning=None,
      finish_reason=@posoco.FinishReason::Stop,
    ),
    usage=Some(usage),
  )
  let foreign : @posoco.EventScope = {
    session_id: @kernel.SessionId::unchecked("s2"),
    run_id: @kernel.RunId::unchecked("r1"),
    turn_id: @kernel.TurnId::unchecked("t1"),
  }
  let local : @posoco.EventScope = {
    session_id: @kernel.SessionId::unchecked("s1"),
    run_id: @kernel.RunId::unchecked("r1"),
    turn_id: @kernel.TurnId::unchecked("t1"),
  }
  goal.on_event_at(Some(local), event)
  assert_eq(goal.usage.total_tokens, 0)
  goal.executing_turn = true
  goal.on_event_at(Some(foreign), event)
  goal.on_event_at(None, event)
  assert_eq(goal.usage.total_tokens, 0)
  goal.on_event_at(Some(local), event)
  assert_eq(goal.usage.total_tokens, 10)
  goal.on_event_at(Some(foreign), @posoco.TurnEvent::TurnCompleted)
  assert_eq(goal.usage.turns, 0)
  goal.on_event_at(Some(local), @posoco.TurnEvent::TurnCompleted)
  assert_eq(goal.usage.turns, 1)
}

test "clearing a running execution cannot destroy its state" {
  let goal = goal_extension(goal_condition="guard")
  goal.status = Running
  goal.executing_loop = true
  goal.current_turn = 2
  goal.clear()
  assert_eq(goal.current_turn, 2)
  assert_true(goal.status == Running)
  goal.executing_loop = false
  goal.clear()
  assert_eq(goal.current_turn, 0)
  assert_true(goal.status == Idle)
}

///|
/// The plan mutates runner state: it may not be scheduled as a parallel tool.
test "goal plan tool executes sequentially" {
  let goal = goal_extension(goal_condition="safe plan updates")
  let definitions = goal.list_tools()
  assert_eq(definitions.length(), 1)
  assert_true(definitions[0].policy == @posoco.ExecutionPolicy::Sequential)
}

///|
/// Absent token telemetry cannot be interpreted as low model output.
test "unknown output usage remains unknown" {
  let goal = goal_extension(goal_condition="unknown output usage")
  goal.executing_turn = true
  goal.active_session_id = Some("s1")
  let scope : @posoco.EventScope = {
    session_id: @kernel.SessionId::unchecked("s1"),
    run_id: @kernel.RunId::unchecked("r1"),
    turn_id: @kernel.TurnId::unchecked("t1"),
  }
  goal.on_event_at(
    Some(scope),
    @posoco.TurnEvent::ModelResponseReceived(
      message=@posoco.Message::AssistantMessage(
        content=[@posoco.Content::Text("still working")],
        tool_calls=[],
        reasoning=None,
        finish_reason=@posoco.FinishReason::Stop,
      ),
      usage=None,
    ),
  )
  assert_false(goal.turn_output_known)
  assert_eq(goal.turn_output_tokens, 0)
  assert_eq(goal.usage.total_tokens, 0)
}
