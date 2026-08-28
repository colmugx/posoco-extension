///|
/// Composition tests: the real posoco Agent wired to a GoalRunner —
/// manifest wiring, catalog exposure, plan rewriting through a scripted
/// tool-call turn, first-turn charter delivery, and error recovery.

///|
/// Compose a real Agent from a ScriptedModel, an io extension, and the goal
/// extension under test, mirroring the host composition pattern.
fn cw_compose_agent(
  model : @posoco.ScriptedModel,
  goal : GoalRunner,
  observers? : Array[&@posoco.Observer] = [],
) -> @posoco.Agent {
  @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)),
      @posoco.tk_ext(id="io", sessions=[
        @posoco.RecordingSessionStore::RecordingSessionStore(),
      ]),
      @posoco.tk_ext(id="obs", observers~),
      goal,
    ],
    config=@posoco.tk_config(),
  ) catch {
    e => abort("Agent failed: \{e}")
  }
}

///|
/// The call must be observed as ToolCallPending strictly before its
/// ToolCallResult, and both must be present.
fn cw_assert_pending_then_result(
  observer : @posoco.RecordingObserver,
  call_id : String,
) -> Unit raise {
  let mut seen_pending = false
  for event in observer.events() {
    match event {
      @posoco.TurnEvent::ToolCallPending(call) =>
        if call.call_id.to_string() == call_id {
          seen_pending = true
        }
      @posoco.TurnEvent::ToolCallResult(call~, ..) =>
        if call.call_id.to_string() == call_id {
          if !seen_pending {
            fail("ToolCallResult before ToolCallPending for \{call_id}")
          }
          return
        }
      _ => ()
    }
  }
  fail("missing pending/result pair for \{call_id}")
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
/// Concatenated text of every message in one recorded model-call input.
fn cw_call_text(model : @posoco.ScriptedModel, call_index : Int) -> String {
  if model.received_messages.length() <= call_index {
    abort("model call \{call_index} was never made")
  }
  let parts : Array[String] = []
  for msg in model.received_messages[call_index] {
    parts.push(text_of_message(msg))
  }
  parts.join("\n")
}

///|
/// Text of the freshly appended input message (the last one) of a recorded
/// model call.
fn cw_latest_input_text(
  model : @posoco.ScriptedModel,
  call_index : Int,
) -> String {
  if model.received_messages.length() <= call_index {
    abort("model call \{call_index} was never made")
  }
  let msgs = model.received_messages[call_index]
  text_of_message(msgs[msgs.length() - 1])
}

///|
test "manifest_reports_v2_ports" {
  let goal = goal_extension(goal_condition="t")
  let manifest = goal.manifest()
  assert_eq(manifest.id, "posoco_ext_goal")
  assert_eq(manifest.hooks.length(), 0)
  assert_eq(manifest.tools.length(), 1)
  assert_eq(manifest.observers.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 0)
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
/// Under core 0.13.0 the system prompt is assembled once per Agent lifetime,
/// so the charter rides the first working turn's user input instead: that
/// turn's input merges the charter above the progress envelope, later turns
/// append user inputs carrying only the progress envelope (the charter
/// survives in the append-only transcript), and no model call ever sees a
/// goal-authored SystemMessage.
async test "charter_rides_first_work_turn_input" {
  let goal = goal_extension(goal_condition="make tests green")
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("working")),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("done\n<goal-complete/>"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("<goal-complete/>"),
    ),
  ])
  let agent = cw_compose_agent(model, goal)
  let result = goal.execute(agent, "session_charter")
  match result.final_status {
    Completed => ()
    other => fail("expected Completed, got \{other}")
  }
  // work → claim → verifier: three model calls.
  assert_eq(model.received_messages.length(), 3)

  // First working turn: charter and progress merged into one user input.
  assert_eq(model.received_messages[0].length(), 1)
  let first_text = cw_call_text(model, 0)
  assert_true(first_text.contains("<goal-context type=\"charter\""))
  assert_true(first_text.contains("Goal: make tests green"))
  assert_true(first_text.contains("<goal-context type=\"progress\""))

  // Claim turn (a later working turn): the freshly appended input message
  // carries progress alone; the earlier merged entry stays in the
  // append-only transcript that precedes it.
  let claim_newest = cw_latest_input_text(model, 1)
  assert_true(claim_newest.contains("<goal-context type=\"progress\""))
  assert_false(claim_newest.contains("<goal-context type=\"charter\""))
  assert_true(cw_call_text(model, 1).contains("<goal-context type=\"charter\""))

  // No goal-injected system message anywhere: with no prompt contributors
  // the hook is not even registered and messages pass through untouched.
  for i in 0..<model.received_messages.length() {
    match model.received_messages[i][0] {
      @posoco.Message::SystemMessage(content~) =>
        for c in content {
          match c {
            @posoco.Content::Text(t) =>
              assert_false(t.contains("posoco_ext_goal"))
            _ => ()
          }
        }
      _ => ()
    }
  }
}

///|
/// Bad args that reach the provider (schema-valid but semantically invalid:
/// zero items) come back as ToolReportedError, the turn recovers, and the
/// plan stays empty. Note: the originally scripted `Json::null()` arguments
/// never reach the provider — the catalog schema validation rejects them
/// pre-execution as NotExecuted, the turn still completes, and the model
/// sees its rejected call on the next step.
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
/// Unknown tool names never corrupt the goal state. The core completes the
/// turn normally: the catalog routes by exact name, the goal provider is
/// never consulted, and the rejected call is reported as ToolCallPending
/// followed by ToolCallResult(NotExecuted). The provider phase below pins
/// the ext's own unknown-name guard.
async test "unknown_tool_name_reported" {
  let goal = goal_extension(goal_condition="unknown tool recovery")
  let model = @posoco.ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response("goal_update_plan_typo", "c2", Json::null()),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("recovered")),
  ])
  let observer = @posoco.RecordingObserver::RecordingObserver()
  let agent = cw_compose_agent(model, goal, observers=[observer])
  let turn = agent.run_turn(@posoco.tk_user_msg("typo tool"), "session_typo")
  assert_eq(goal.plan().items.length(), 0)
  assert_eq(turn.tool_results.length(), 1)
  match turn.tool_results[0] {
    @posoco.ToolOutcome::NotExecuted(
      reason=@posoco.NotExecutedReason::UnknownTool,
      ..
    ) => ()
    _ => fail("expected NotExecuted(UnknownTool) for the unknown tool call")
  }
  cw_assert_pending_then_result(observer, "c2")

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
