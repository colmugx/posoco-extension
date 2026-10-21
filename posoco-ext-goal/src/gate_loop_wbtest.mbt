///|
/// Trusted test-only verifier: fixture references stand in for externally
/// checked acceptance records. Production must supply its own verifier.
struct TestGoalVerifier {
  mut calls : Int32
  reject_first : Bool
}

///|
pub impl GoalVerifier for TestGoalVerifier with fn verify(
  self : TestGoalVerifier,
  request : GoalVerificationRequest,
) -> GoalAssessment {
  self.calls += 1
  if self.reject_first && self.calls == 1 {
    return Rejected("the acceptance check failed")
  }
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
  reject_first_verification~ : Bool = false,
) -> @posoco.Agent {
  if verified {
    goal.set_verifier(TestGoalVerifier::{
      calls: 0,
      reject_first: reject_first_verification,
    })
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
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let goal = goal_extension(goal_condition="make the build green")
  let agent = gate_build_agent(goal, model, store)
  let result = goal.execute(agent, "session_gate_confirm")
  match result.final_status {
    Completed => ()
    other => fail("expected Completed, got \{other}")
  }
  assert_eq(result.turns_completed, 2)
  assert_eq(result.history.length(), 2)
  assert_eq(model.call_count(), 2)
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
      @posoco.tk_stop_response("fixed\n<goal-complete/>"),
    ),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let goal = goal_extension(goal_condition="make the build green")
  let agent = gate_build_agent(goal, model, store, reject_first_verification=true)
  let result = goal.execute(agent, "session_gate_retract")
  match result.final_status {
    Completed => ()
    other => fail("expected Completed, got \{other}")
  }
  assert_eq(result.turns_completed, 3)
  assert_eq(result.history.length(), 3)
  // One model call per turn here; index 3 is the turn after the rejection.
  assert_eq(model.received_messages.length(), 3)
  assert_true(gate_model_input_text(model, 2).contains("failed verification"))
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
    Paused => ()
    other => fail("expected Paused, got \{other}")
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
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = gate_build_agent(goal, model, store)
  let result = goal.execute(agent, "session_gate_budget_cap")
  match result.final_status {
    Completed => ()
    other => fail("expected Completed, got \{other}")
  }
  assert_eq(result.turns_completed, 1)
  assert_eq(model.call_count(), 1)
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
  assert_eq(result.turns_completed, 2)
  assert_eq(model.call_count(), 3) // work + (plan tool + finish) + verifier
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
  assert_eq(second.turns_completed, 2)
  assert_eq(second.history.length(), 2)
  assert_eq(model.call_count(), 2)
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
  ])
  let next_agent = gate_build_agent(next_goal, next_model, store)
  next_goal.resume_goal()
  let result = next_goal.execute(next_agent, "durable_session")
  assert_true(result.final_status == Completed)
  assert_eq(result.turns_completed, 2)
  assert_eq(result.history.length(), 2)
  assert_eq(next_model.call_count(), 1)
  let restored_messages = next_model.received_messages[0]
  let latest_prompt = text_of_message(
    restored_messages[restored_messages.length() - 1],
  )
  assert_false(latest_prompt.contains("<goal-context type=\"charter\""))
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


///|
/// Semantic DecisionPort advice cannot certify the goal on its own.
async test "decision adviser is optional and not completion authority" {
  let decision = @posoco.ScriptedDecisionPort::ScriptedDecisionPort([
    @posoco.ScriptedDecisionStep::Return({
      answers: [
        @posoco.DecisionAnswer::BooleanAnswer(
          id="goal_satisfied",
          probability_true=0.99,
        ),
      ],
      model: Some("fake-judge"),
      usage: None,
    }),
  ])
  let goal = goal_extension(goal_condition="no evidence despite confidence")
  goal.set_decision_adviser(decision)
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
  let result = goal.execute(agent, "semantic_session")
  assert_true(result.final_status == Paused)
  assert_eq(decision.call_count(), 1)
  assert_eq(result.semantic_probability, Some(0.99))
  match result.assessment {
    Inconclusive(_) => ()
    _ => fail("semantic probability must not become verified completion")
  }
}

///|
/// Evidence must cover every explicit criterion, with nonempty provenance.
test "partial evidence never validates as completed" {
  let evidence = Verified([
    GoalEvidence::{ criterion: "tests", source: "test-command", reference: "run42", },
  ])
  match evidence.validated(["tests", "build"]) {
    Inconclusive(reason) => assert_true(reason.contains("build"))
    _ => fail("unverified acceptance item was accepted")
  }
  match GoalAssessment::Verified([]).validated(["tests"]) {
    Inconclusive(_) => ()
    _ => fail("empty evidence was accepted")
  }
}

///|
/// Semantic fallback does not require a composed DecisionPort.
test "opted in goal composes without decision capability" {
  let goal = goal_extension(goal_condition="plain Cetas JS host")
  goal.options.enable_semantic_advice = true
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("fine")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = gate_build_agent(goal, model, store)
  ignore(agent)
  assert_true(goal.adviser is None)
}


///|
/// A composed DecisionPort is discovered only when explicitly enabled. It
/// remains advisory: the trusted GoalVerifier is still the sole completion
/// authority.
async test "composed decision provider gives optional semantic advice" {
  let decision = @posoco.ScriptedDecisionPort::ScriptedDecisionPort([
    @posoco.ScriptedDecisionStep::Return({
      answers: [
        @posoco.DecisionAnswer::BooleanAnswer(
          id="goal_satisfied",
          probability_true=0.75,
        ),
      ],
      model: Some("scripted-semantic-judge"),
      usage: None,
    }),
  ])
  let goal = goal_extension(goal_condition="semantic composition")
  goal.options.enable_semantic_advice = true
  goal.set_verifier(TestGoalVerifier::{ calls: 0, reject_first: false, })
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("done\n<goal-complete/>"),
    ),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="decision", decision=Some(decision)),
      @posoco.tk_ext(id="io", sessions=[store]),
      goal,
    ],
    config=@posoco.tk_config(),
  ) catch {
    e => abort("composition failed: \{e}")
  }
  let result = goal.execute(agent, "composition_semantic")
  assert_true(result.final_status == Completed)
  assert_eq(result.semantic_probability, Some(0.75))
  assert_eq(decision.call_count(), 1)
}

///|
/// A failing DecisionPort is a missing advisory signal, not a hard
/// dependency or a reason to discard authoritative verifier evidence.
async test "decision provider failure falls back without changing verdict" {
  let decision = @posoco.ScriptedDecisionPort::ScriptedDecisionPort([
    @posoco.ScriptedDecisionStep::Fail(
      @posoco.DecisionError::Transport("provider unavailable"),
    ),
  ])
  let goal = goal_extension(goal_condition="decision service down")
  goal.set_decision_adviser(decision)
  goal.set_verifier(TestGoalVerifier::{ calls: 0, reject_first: false, })
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("done\n<goal-complete/>"),
    ),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = gate_build_agent(goal, model, store, verified=false)
  let result = goal.execute(agent, "semantic_failure")
  assert_true(result.final_status == Completed)
  assert_eq(result.semantic_probability, None)
  assert_eq(decision.call_count(), 1)
}


///|
/// A high confidence semantic prediction can defer one deterministic stall,
/// but cannot extend a hard turn budget or confer completion authority.
async test "semantic adviser can defer a stall for one bounded work turn" {
  let decision = @posoco.ScriptedDecisionPort::ScriptedDecisionPort([
    @posoco.ScriptedDecisionStep::Return({
      answers: [
        @posoco.DecisionAnswer::BooleanAnswer(
          id="goal_continue_has_value",
          probability_true=0.95,
        ),
      ],
      model: None,
      usage: None,
    }),
    @posoco.ScriptedDecisionStep::Return({
      answers: [
        @posoco.DecisionAnswer::BooleanAnswer(
          id="goal_satisfied",
          probability_true=0.80,
        ),
      ],
      model: None,
      usage: None,
    }),
  ])
  let goal = goal_extension(goal_condition="rescue bounded stall")
  goal.options.stall_turn_threshold = 1
  goal.options.stall_min_tokens = 0
  goal.set_decision_adviser(decision)
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("thinking before evidence"),
    ),
    @posoco.ScriptedModelStep::Respond(
      @posoco.tk_stop_response("done\n<goal-complete/>"),
    ),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = gate_build_agent(goal, model, store)
  let result = goal.execute(agent, "stall_deferral")
  assert_true(result.final_status == Completed)
  assert_eq(result.turns_completed, 2)
  assert_eq(goal.semantic_stall_deferrals, 1)
  assert_eq(decision.call_count(), 2)
}

///|
/// A semantic provider must never indefinitely override a deterministic
/// stall. The policy defaults to at most one override.
async test "semantic stall deferral count is strictly bounded" {
  let decision = @posoco.ScriptedDecisionPort::ScriptedDecisionPort([
    @posoco.ScriptedDecisionStep::Return({
      answers: [
        @posoco.DecisionAnswer::BooleanAnswer(
          id="goal_continue_has_value",
          probability_true=0.99,
        ),
      ],
      model: None,
      usage: None,
    }),
  ])
  let goal = goal_extension(goal_condition="do not loop forever")
  goal.options.stall_turn_threshold = 1
  goal.options.stall_min_tokens = 0
  goal.set_decision_adviser(decision)
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("thinking")),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("still thinking")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = gate_build_agent(goal, model, store)
  let result = goal.execute(agent, "bounded_stall")
  assert_true(result.final_status == Paused)
  assert_eq(result.turns_completed, 2)
  assert_eq(goal.semantic_stall_deferrals, 1)
  assert_eq(decision.call_count(), 1)
}

///|
/// Even a confident semantic continuation cannot evade the user's hard
/// max_turns limit.
async test "semantic adviser cannot override an exhausted turn budget" {
  let decision = @posoco.ScriptedDecisionPort::ScriptedDecisionPort([])
  let goal = goal_extension(goal_condition="hard budget wins")
  goal.options.budget.max_turns = 1
  goal.options.stall_turn_threshold = 1
  goal.options.stall_min_tokens = 0
  goal.set_decision_adviser(decision)
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("thinking")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let agent = gate_build_agent(goal, model, store)
  let result = goal.execute(agent, "hard_budget")
  assert_true(result.final_status == Paused)
  assert_eq(decision.call_count(), 0)
  assert_eq(goal.semantic_stall_deferrals, 0)
}
