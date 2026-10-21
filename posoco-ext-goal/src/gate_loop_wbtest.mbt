///|
/// Trusted test-only verifier: fixture references stand in for externally
/// checked acceptance records. Production must supply its own verifier.
struct TestGoalVerifier {}

///|
pub impl GoalVerifier for TestGoalVerifier with fn verify(
  _self : TestGoalVerifier,
  request : GoalVerificationRequest,
) -> GoalAssessment {
  let names = if request.criteria.is_empty() {
    ["goal"]
  } else {
    request.criteria
  }
  Verified(names.map(fn(name) {
    GoalEvidence::{ criterion: name, source: "test-fixture", reference: "ok", }
  }))
}

///|
/// Compose model + sessions + one GoalRunner into an Agent (testkit shape).
fn gate_build_agent(
  goal : GoalRunner,
  model : @posoco.ScriptedModel,
  store : @posoco.RecordingSessionStore,
  verified~ : Bool = true,
) -> @posoco.Agent {
  if verified {
    goal.set_verifier(TestGoalVerifier::{})
  }
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
fn gate_usage_step(text : String, total : Int32) -> @posoco.ScriptedModelStep {
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
  let result : @posoco.ModelCallResult = { completion, processed_messages: [], }
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
fn gate_model_input_text(
  model : @posoco.ScriptedModel,
  index : Int32,
) -> String {
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
      @posoco.tk_stop_response("item 1 failed\n<goal-blocked/>"),
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
/// consuming the rest of the script.
async test "budget exhaustion stops without consuming extra model steps" {
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


///|
async test "goal resume preserves charter, history and turn budget" {
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("step one")),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("done\n<goal-complete/>"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("<goal-complete/>"),
    ),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let goal = goal_extension(goal_condition="test resume")
  // Force a pause after exactly one productive working turn.
  goal.options.budget.max_turns = 4
  goal.options.stall_turn_threshold = 1
  goal.options.stall_min_tokens = 1000000
  let agent = gate_build_agent(goal, model, store)
  let first = goal.execute(agent, "resume_session")
  assert_true(first.final_status == Paused)
  assert_eq(first.turns_completed, 1)
  assert_eq(first.history.length(), 1)
  assert_true(goal.charter_delivered)
  // Disable artificial stall; explicit resume should not re-arm charter.
  goal.options.stall_turn_threshold = 100
  goal.resume_goal()
  let second = goal.execute(agent, "resume_session")
  assert_true(second.final_status == Completed)
  assert_eq(second.turns_completed, 3)
  assert_eq(second.history.length(), 3)
  assert_eq(model.call_count(), 3)
  assert_true(!gate_model_input_text(model, 1).contains("<goal-context>"))
}

///|
async test "goal execute rejects foreign resume session without resetting state" {
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("step one")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let goal = goal_extension(goal_condition="test isolation")
  goal.options.stall_turn_threshold = 1
  goal.options.stall_min_tokens = 1000000
  let agent = gate_build_agent(goal, model, store)
  let first = goal.execute(agent, "original_session")
  assert_true(first.final_status == Paused)
  let snapshot = goal.execute(agent, "other_session")
  match snapshot.final_status {
    Failed(reason) => assert_true(reason.contains("different session"))
    other => fail("expected session mismatch, got \{other}")
  }
  assert_eq(goal.current_turn, 1)
  assert_eq(goal.history.length(), 1)
  assert_eq(model.call_count(), 1)
}

///|
/// Without an independent verifier, repeating the completion marker
/// produces an inconclusive result, never Completed.
async test "unverified_claim_pauses_not_completes" {
  let goal = goal_extension(goal_condition="cannot self-certify")
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("done\n<goal-complete/>"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("<goal-complete/>"),
    ),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = gate_build_agent(goal, model, store, verified=false)
  let result = goal.execute(agent, "unverified_session")
  assert_true(result.final_status == Paused)
  match result.assessment {
    Inconclusive(reason) => assert_true(reason.contains("no independent"))
    other => fail("expected Inconclusive, got \{Repr(other)}")
  }
}


///|
/// A paused goal survives a runner restart when a host persists the
/// checkpoint together with the original session store.
async test "goal checkpoint round trip resumes on a new runner" {
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let first_model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("step one")),
  ])
  let first_goal = goal_extension(goal_condition="durable goal")
  first_goal.options.stall_turn_threshold = 1
  first_goal.options.stall_min_tokens = 1000000
  let first_agent = gate_build_agent(first_goal, first_model, store)
  let paused = first_goal.execute(first_agent, "durable_session")
  assert_true(paused.final_status == Paused)
  let saved = match first_goal.checkpoint() {
    Ok(v) => v
    Err(e) => fail("checkpoint failed: \{e}")
  }
  let next_goal = goal_extension(goal_condition="durable goal")
  match next_goal.restore_checkpoint(saved) {
    Ok(_) => ()
    Err(e) => fail("restore failed: \{e}")
  }
  assert_eq(next_goal.current_turn, 1)
  assert_eq(next_goal.history.length(), 1)
  assert_true(next_goal.charter_delivered)
  let next_model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("done\n<goal-complete/>"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("<goal-complete/>"),
    ),
  ])
  let next_agent = gate_build_agent(next_goal, next_model, store)
  next_goal.resume_goal()
  let result = next_goal.execute(next_agent, "durable_session")
  assert_true(result.final_status == Completed)
  assert_eq(result.turns_completed, 3)
  assert_eq(result.history.length(), 3)
  assert_eq(next_model.call_count(), 2)
  assert_false(gate_model_input_text(next_model, 0).contains(
    "<goal-context type=\"charter\"",
  ))
}

///|
test "checkpoint rejects another goal without touching runner state" {
  let original = goal_extension(goal_condition="same contract")
  original.status = Paused
  original.active_session_id = Some("original")
  let snapshot = match original.checkpoint() {
    Ok(v) => v
    Err(e) => fail("checkpoint failed: \{e}")
  }
  let other = goal_extension(goal_condition="different contract")
  match other.restore_checkpoint(snapshot) {
    Err(reason) => assert_true(reason.contains("contract mismatch"))
    Ok(_) => fail("must reject a foreign contract")
  }
  assert_true(other.status == Idle)
  assert_eq(other.current_turn, 0)
}
