///|
/// Composition tests: the real posoco Agent wired to a GoalRunner —
/// manifest wiring, catalog exposure, plan rewriting through a scripted
/// tool-call turn, charter injection, and error recovery.

///|
/// Compose a real Agent from a ScriptedModel, an io extension, and the goal
/// extension under test, mirroring the host composition pattern.
fn cw_compose_agent(
  model : @posoco.ScriptedModel,
  goal : GoalRunner,
) -> @posoco.Agent {
  @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)),
      @posoco.tk_ext(id="io", sessions=[
        @posoco.RecordingSessionStore::RecordingSessionStore(),
      ]),
      goal,
    ],
    config=@posoco.tk_config(),
  ) catch {
    e => abort("Agent failed: \{e}")
  }
}

///|
/// Run one user turn; abort loudly if the agent raises instead of completing.
async fn cw_run_turn(
  agent : @posoco.Agent,
  text : String,
  session_id : String,
) -> @posoco.TurnResult {
  agent.run_turn(@posoco.tk_user_msg(text), session_id) catch {
    e => abort("run_turn raised: \{e.to_string()}")
  }
}

///|
/// One plan-item JSON object: {"title": t, "status": s}.
fn cw_plan_item(title : String, status : String) -> Json {
  Json::object(
    Map::from_array([
      ("title", Json::string(title)),
      ("status", Json::string(status)),
    ]),
  )
}

///|
/// First Content Text of the SystemMessage at index 0 of the given model call.
fn cw_system_text(model : @posoco.ScriptedModel, call_index : Int) -> String {
  if model.received_messages.length() <= call_index {
    abort("model call \{call_index} was never made")
  }
  match model.received_messages[call_index][0] {
    @posoco.Message::SystemMessage(content~) =>
      match content {
        [@posoco.Content::Text(t), ..] => t
        _ => abort("system message content should begin with text")
      }
    _ => abort("model call \{call_index}: message 0 should be a SystemMessage")
  }
}

///|
test "manifest_reports_v2_ports" {
  let goal = goal_extension(goal_condition="t")
  let manifest = goal.manifest()
  assert_eq(manifest.id, "posoco_ext_goal")
  assert_eq(manifest.hooks.length(), 0)
  assert_eq(manifest.tools.length(), 1)
  assert_eq(manifest.observers.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 1)
}

///|
test "agent_composes_with_goal" {
  let goal = goal_extension(goal_condition="compose check")
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("hi")),
  ])
  let agent = cw_compose_agent(model, goal)
  ignore(agent)
}

///|
async test "plan_tool_in_catalog" {
  let goal = goal_extension(goal_condition="catalog check")
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("hi")),
  ])
  let agent = cw_compose_agent(model, goal)
  let turn = cw_run_turn(agent, "hello", "session_catalog")
  assert_eq(turn.final_session_id, "session_catalog")
  assert_eq(model.received_tools.length(), 1)
  let mut found = false
  for def in model.received_tools[0] {
    if def.name.to_string() == "goal_update_plan" {
      found = true
    }
  }
  assert_true(found)
  assert_eq(goal.plan().items.length(), 0)
}

///|
async test "update_plan_tool_rewrites_state_through_agent" {
  let goal = goal_extension(goal_condition="rewrite through agent")
  let args = Json::object(
    Map::from_array([
      (
        "items",
        Json::array([
          cw_plan_item("step one", "pending"),
          cw_plan_item("step two", "in_progress"),
          cw_plan_item("step three", "in_progress"),
        ]),
      ),
    ]),
  )
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response("goal_update_plan", "c1", args),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("planned")),
  ])
  let agent = cw_compose_agent(model, goal)
  let turn = cw_run_turn(agent, "make a plan", "session_rewrite")

  let plan = goal.plan()
  assert_eq(plan.items.length(), 3)
  assert_eq(plan.items[0].title, "step one")
  assert_eq(plan.items[0].status, Pending)
  assert_eq(plan.items[1].title, "step two")
  assert_eq(plan.items[1].status, InProgress)
  assert_eq(plan.items[2].title, "step three")
  assert_eq(plan.items[2].status, Pending)
  let mut done = 0
  let mut in_progress = 0
  for item in plan.items {
    match item.status {
      Done => done = done + 1
      InProgress => in_progress = in_progress + 1
      Pending => ()
    }
  }
  assert_eq(in_progress, 1)
  assert_eq(done, 0)

  assert_true(turn.tool_results.length() > 0)
  match turn.tool_results[0] {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("0/3"))
    _ => fail("expected the plan tool to report Success")
  }
}

///|
async test "charter_injected_as_stable_system_message" {
  let goal = goal_extension(goal_condition="make tests green")
  goal.charter = build_charter(
    goal_condition="make tests green",
    checklist=[],
    completion_marker="<goal-complete/>",
    blocked_marker="<goal-blocked/>",
    plan_tool_name="goal_update_plan",
  )
  goal.status = Running
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("one")),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("two")),
  ])
  let agent = cw_compose_agent(model, goal)
  ignore(cw_run_turn(agent, "first", "session_charter"))
  ignore(cw_run_turn(agent, "second", "session_charter"))

  let sys1 = cw_system_text(model, 0)
  let sys2 = cw_system_text(model, 1)
  assert_true(sys1.contains("posoco_ext_goal:"))
  assert_true(sys1.contains("<goal-context type=\"charter\""))
  assert_true(sys1.contains("Goal: make tests green"))
  assert_eq(sys2, sys1)
}

///|
/// Bad args that reach the provider (schema-valid but semantically invalid:
/// zero items) come back as ToolReportedError, the turn recovers, and the
/// plan stays empty. Spec deviation note: the originally scripted
/// `Json::null()` arguments never reach the provider — posoco 0.12.0's
/// catalog schema validation rejects them pre-execution, and an all-rejected
/// tool wave makes `run_turn` RAISE `AgentError::Runtime` (the reducer emits
/// ToolCompleted without ToolBatchStarted; the agent event subscriber treats
/// that as a contract violation). See unknown_tool_name_reported.
async test "bad_tool_args_reported_not_crashed" {
  let goal = goal_extension(goal_condition="bad args recovery")
  let args = Json::object(Map::from_array([("items", Json::array([]))]))
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response("goal_update_plan", "c9", args),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("recovered")),
  ])
  let agent = cw_compose_agent(model, goal)
  let turn = cw_run_turn(agent, "bad args", "session_bad_args")
  assert_eq(goal.plan().items.length(), 0)
  assert_eq(model.received_messages.length(), 2)
  assert_true(turn.tool_results.length() > 0)
  match turn.tool_results[0] {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_eq(content, "plan must contain at least one item")
    _ => fail("expected the plan tool to report a bad-args error")
  }
}

///|
/// Unknown tool names never corrupt the goal state. Spec deviation note:
/// posoco 0.12.0 does NOT complete such a turn — the catalog routes by exact
/// name, the goal provider is never consulted, and the all-rejected wave
/// raises `AgentError::Runtime` from `run_turn` (ToolCompleted without
/// ToolBatchStarted → agent event subscriber ContractViolation). The agent
/// phase below accepts completion (per spec) or the known raise (per the
/// current core); the provider phase pins the ext's own unknown-name guard.
async test "unknown_tool_name_reported" {
  let goal = goal_extension(goal_condition="unknown tool recovery")
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response("goal_update_plan_typo", "c2", Json::null()),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("recovered")),
  ])
  let agent = cw_compose_agent(model, goal)
  let outcome : Result[@posoco.TurnResult, String] = Ok(
    agent.run_turn(@posoco.tk_user_msg("typo tool"), "session_typo"),
  ) catch {
    e => Err(e.to_string())
  }
  match outcome {
    Ok(_) => ()
    Err(msg) => assert_true(msg.contains("SubscriberFailed"))
  }
  assert_eq(goal.plan().items.length(), 0)

  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("c3"),
    name: @posoco.ToolName::unchecked("goal_update_plan_typo"),
    arguments: Json::null(),
  }
  match @posoco.ToolProvider::execute(goal, "goal_update_plan_typo", call) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_eq(content, "unknown tool")
    _ => fail("expected ToolReportedError for a name the provider does not own")
  }
}
