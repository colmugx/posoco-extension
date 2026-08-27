///|
/// Loop-level white-box tests for GoalRunner::execute: the verifier gate
/// (confirm / retract / budget), verifier turns counting against the turn
/// budget, the wrap-up turn mutating the plan, and the three stall detectors.

///|
/// Compose model + sessions + one GoalRunner into an Agent (testkit shape).
fn gate_build_agent(
  goal : GoalRunner,
  model : @posoco.ScriptedModel,
  store : @posoco.RecordingSessionStore,
) -> @posoco.Agent {
  @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store]),
      goal,
    ],
    config=@posoco.tk_config(),
  ) catch {
    e => abort("Agent failed: \{e}")
  }
}

///|
/// Stop response reporting `total` tokens (split evenly input/output) so the
/// Observer accumulates usage.
fn gate_usage_step(text : String, total : Int) -> @posoco.ScriptedModelStep {
  let usage : @posoco.Usage = {
    input_tokens: Some(total / 2),
    output_tokens: Some(total / 2),
    total_tokens: Some(total),
    cached_input_tokens: None,
    uncached_input_tokens: None,
  }
  let completion : @posoco.Completion = @posoco.Completion(
    content=[@posoco.Content::Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=Some(usage),
  )
  let result : @posoco.ModelCallResult = { completion, processed_messages: [] }
  @posoco.ScriptedModelStep::Respond(result)
}

///|
/// goal_update_plan arguments: one in_progress item "fix parser".
fn gate_plan_args() -> Json {
  Json::object(
    Map::from_array([
      (
        "items",
        Json::array([
          Json::object(
            Map::from_array([
              ("title", Json::string("fix parser")),
              ("status", Json::string("in_progress")),
            ]),
          ),
        ]),
      ),
    ]),
  )
}

///|
/// Concatenated text of every message in one recorded model-call input.
fn gate_model_input_text(model : @posoco.ScriptedModel, index : Int) -> String {
  let parts : Array[String] = []
  for msg in model.received_messages[index] {
    parts.push(text_of_message(msg))
  }
  parts.join("\n")
}

///|
/// Work claim, then a verifier turn that confirms → Completed after exactly
/// work + claim + verifier turns.
async test "gate_confirm_completes" {
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("working")),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("done\n<goal-complete/>"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("<goal-complete/>"),
    ),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let goal = goal_extension(goal_condition="make the build green")
  let agent = gate_build_agent(goal, model, store)
  let result = goal.execute(agent, "session_gate_confirm")
  match result.final_status {
    Completed => ()
    other => fail("expected Completed, got \{other}")
  }
  assert_eq(result.turns_completed, 3)
  assert_eq(result.history.length(), 3)
  assert_eq(model.call_count(), 3)
}

///|
/// Verifier rejection retracts the claim; the next work turn's input carries
/// the failed-verification intro; a later claim is confirmed.
async test "gate_retract_then_confirm" {
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("working")),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("claim\n<goal-complete/>"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("<goal-blocked/>\nitem 1 failed"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("fixed\n<goal-complete/>"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("<goal-complete/>"),
    ),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let goal = goal_extension(goal_condition="make the build green")
  let agent = gate_build_agent(goal, model, store)
  let result = goal.execute(agent, "session_gate_retract")
  match result.final_status {
    Completed => ()
    other => fail("expected Completed, got \{other}")
  }
  assert_eq(result.turns_completed, 5)
  assert_eq(result.history.length(), 5)
  // One model call per turn here; index 3 is the turn after the rejection.
  assert_eq(model.received_messages.length(), 5)
  assert_true(gate_model_input_text(model, 3).contains("failed verification"))
}

///|
/// A work-turn claim with zero verifier rounds available is Blocked, not
/// routed to a verifier turn.
async test "verifier_budget_exhausted" {
  let options = GoalOptions::default(goal_condition="no verifier rounds")
  options.max_verifier_rounds = 0
  let goal = GoalRunner(options~)
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("done\n<goal-complete/>"),
    ),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = gate_build_agent(goal, model, store)
  let result = goal.execute(agent, "session_gate_no_verifier")
  match result.final_status {
    Blocked(reason) => assert_eq(reason, "verification budget exhausted")
    other => fail("expected Blocked, got \{other}")
  }
  assert_eq(result.turns_completed, 1)
}

///|
/// The verifier turn counts against budget.max_turns, but a confirm exactly
/// at the cap completes the run instead of tripping BudgetExhausted.
async test "verifier_turns_count_against_budget" {
  let options = GoalOptions::default(goal_condition="cap the run")
  options.budget.max_turns = 2
  let goal = GoalRunner(options~)
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("claim\n<goal-complete/>"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("<goal-complete/>"),
    ),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = gate_build_agent(goal, model, store)
  let result = goal.execute(agent, "session_gate_budget_cap")
  match result.final_status {
    Completed => ()
    other => fail("expected Completed, got \{other}")
  }
  assert_eq(result.turns_completed, 2)
  assert_eq(model.call_count(), 2)
}

///|
/// Crossing the wrap-up ratio sends the one-shot wrap-up prompt; the model
/// rewrites the plan via the plan tool mid-turn, then claims completion,
/// and the verifier confirms. The final plan reflects the tool mutation.
async test "wrapup_updates_plan_and_claims" {
  let options = GoalOptions::default(goal_condition="finish the feature")
  options.budget.max_total_tokens = 100
  options.wrapup_ratio = 0.5
  let goal = GoalRunner(options~)
  let model = @posoco.ScriptedModel::ScriptedModel([
    gate_usage_step("step", 80),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response("goal_update_plan", "c1", gate_plan_args()),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("updated\n<goal-complete/>"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("<goal-complete/>"),
    ),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = gate_build_agent(goal, model, store)
  let result = goal.execute(agent, "session_gate_wrapup")
  match result.final_status {
    Completed => ()
    other => fail("expected Completed, got \{other}")
  }
  assert_eq(result.final_plan.items.length(), 1)
  assert_eq(result.final_plan.items[0].status, InProgress)
  assert_eq(result.final_plan.items[0].title, "fix parser")
  assert_true(goal.wrapup_sent)
  assert_eq(result.turns_completed, 3)
  assert_eq(model.call_count(), 4) // work + (plan tool + finish) + verifier
}

///|
/// Two identical consecutive tool calls (same name and arguments, distinct
/// call ids) with stall_repeat_threshold=2 pause the run; the token stall is
/// disabled via stall_min_tokens=0 and the plan never changes so only the
/// repetition detector can fire.
async test "stall_repeated_tool_calls_pause" {
  let options = GoalOptions::default(goal_condition="loop the same call")
  options.stall_repeat_threshold = 2
  options.stall_min_tokens = 0
  let goal = GoalRunner(options~)
  let args = gate_plan_args()
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response("goal_update_plan", "c1", args),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("no signal")),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_tool_call_response("goal_update_plan", "c2", args),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("no signal")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = gate_build_agent(goal, model, store)
  let result = goal.execute(agent, "session_gate_repeat")
  match result.final_status {
    Paused => ()
    other => fail("expected Paused, got \{other}")
  }
  match result.stall_reason {
    Some(reason) => assert_eq(reason, "repeated identical tool calls")
    None => fail("expected a stall reason")
  }
  assert_eq(result.turns_completed, 2)
}

///|
/// Marker-free, tool-free turns over an unchanged plan pause once
/// stall_turn_threshold turns elapse. stall_min_tokens=0 disables the token
/// detector (delta < 0 is never true) and no tool calls occur, so the plan
/// detector is the only one that can fire.
async test "stall_plan_frozen_pause" {
  let options = GoalOptions::default(goal_condition="think forever")
  options.stall_turn_threshold = 2
  options.stall_min_tokens = 0
  let goal = GoalRunner(options~)
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("thinking")),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("still thinking"),
    ),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = gate_build_agent(goal, model, store)
  let result = goal.execute(agent, "session_gate_frozen")
  match result.final_status {
    Paused => ()
    other => fail("expected Paused, got \{other}")
  }
  match result.stall_reason {
    Some(reason) => assert_eq(reason, "plan unchanged")
    None => fail("expected a stall reason")
  }
  assert_eq(result.turns_completed, 2)
}

///|
/// A run that neither signals nor stalls stops at budget.max_turns without
/// consuming the rest of the script (regression: without the budget check the
/// loop would exhaust ScriptedModel and surface Failed instead).
async test "budget_exhaustion_regression" {
  let options = GoalOptions::default(goal_condition="never finishes")
  options.budget.max_turns = 2
  let goal = GoalRunner(options~)
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("still working"),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("more work")),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("unreached")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = gate_build_agent(goal, model, store)
  let result = goal.execute(agent, "session_gate_exhaust")
  match result.final_status {
    BudgetExhausted => ()
    other => fail("expected BudgetExhausted, got \{other}")
  }
  assert_true(result.turns_completed <= 2)
  assert_eq(model.call_count(), 2)
}
