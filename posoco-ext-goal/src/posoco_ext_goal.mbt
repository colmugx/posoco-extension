///|
/// posoco_ext_goal — Goal-driven autonomous looping extension for Posoco.
/// Compose it like any other extension — see `goal_extension`.

///|
fn truncate_text(text : String, max_len : Int32) -> String {
  if text.length() > max_len {
    text[0:max_len].to_owned() + "…"
  } else {
    text
  }
}

///|
pub(all) enum GoalStatus {
  Idle // No goal set
  Running // Actively pursuing a goal
  Paused // Goal paused (user or stall detection)
  Completed // Goal condition satisfied and verified
  Blocked(String) // Agent declared it cannot proceed
  BudgetExhausted // Hit turn or token limit
  Failed(String) // Error during execution
} derive(Eq, Debug)

///|
pub extend GoalStatus with Eq::{not_equal, equal}

///|
pub extend GoalStatus with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub impl Show for GoalStatus with fn to_string(self) -> String {
  match self {
    Idle => "Idle"
    Running => "Running"
    Paused => "Paused"
    Completed => "Completed"
    Blocked(reason) => "Blocked(\{reason})"
    BudgetExhausted => "BudgetExhausted"
    Failed(msg) => "Failed(\{msg})"
  }
}

///|
pub extend GoalStatus with Show::{to_string, output}

///|
/// Budget limits. All fields default to 0 (unlimited).
pub(all) struct GoalBudget {
  mut max_turns : Int32
  mut max_total_tokens : Int32
} derive(Debug)

///|
pub extend GoalBudget with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Accumulated usage counters, updated by the Observer impl.
pub(all) struct GoalUsage {
  mut turns : Int32
  mut total_tokens : Int32
} derive(Debug, Eq)

///|
pub extend GoalUsage with Eq::{not_equal, equal}

///|
pub extend GoalUsage with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) struct GoalOptions {
  goal_condition : String
  budget : GoalBudget
  completion_marker : String // "<goal-complete/>"
  blocked_marker : String // "<goal-blocked/>"
  mut wrapup_ratio : Double // e.g. 0.9 = trigger wrap-up at 90% budget
  mut stall_turn_threshold : Int32 // consecutive low-output/unchanged-plan turns
  mut stall_min_tokens : Int32 // what counts as "low output"
  completion_checklist : Array[String] // empty = implicit whole-goal item
  mut max_verifier_rounds : Int32 // completion claims routed to a verifier turn
  mut stall_repeat_threshold : Int32 // consecutive identical tool calls
  mut plan_tool_name : String
  mut enable_semantic_advice : Bool // opt-in; may disclose claim context to DecisionPort
  mut max_semantic_stall_deferrals : Int32 // bounded rescue attempts, default 1
  mut semantic_stall_threshold : Double // strictly advisory probability gate
} derive(Debug)

///|
pub extend GoalOptions with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One entry per completed turn in the execute loop.
pub(all) struct GoalHistoryEntry {
  turn : Int32
  usage : GoalUsage
  summary : String
} derive(Eq, Debug)

///|
pub extend GoalHistoryEntry with Eq::{not_equal, equal}

///|
pub extend GoalHistoryEntry with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Final result returned by GoalRunner.execute().
pub(all) struct GoalResult {
  final_status : GoalStatus
  total_usage : GoalUsage
  turns_completed : Int32
  history : Array[GoalHistoryEntry]
  final_plan : GoalPlan
  stall_reason : String?
  assessment : GoalAssessment
  semantic_probability : Double?
} derive(Debug)

///|
pub extend GoalResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Central struct: ToolProvider + Observer + the execute() loop.
///
/// The run charter is built at each `execute()` start from the goal options
/// and delivered once, on the run's first working turn, merged above that
/// turn's progress envelope. Later turns carry the progress envelope alone;
/// the charter stays in the append-only transcript. The core's system prompt
/// is static (one lazy injection per Agent lifetime) and is never touched by
/// this extension. Hosts drive the runner through `execute`, `status`,
/// `pause`, `resume_goal`, `plan` and `clear`; the mutable bookkeeping stays
/// package-private.
pub struct GoalRunner {
  mut options : GoalOptions
  mut status : GoalStatus
  mut usage : GoalUsage
  mut history : Array[GoalHistoryEntry]
  mut current_turn : Int32
  mut last_total_tokens : Int32 // retained for legacy telemetry/debugging
  mut turn_output_known : Bool // whether usage reported actual output tokens
  mut turn_output_tokens : Int32 // output only: input tokens do not show work
  mut turn_tool_count : Int32 // activity in current turn, not plan mutation
  mut stall_count : Int32 // consecutive low-output turns
  mut wrapup_sent : Bool // prevent duplicate wrap-up
  mut plan : GoalPlan // replaced wholesale by the plan tool / reset
  mut charter : String // rebuilt at each execute() start from options
  mut charter_delivered : Bool // true once this run's first working turn carried the charter
  mut completion_claimed : Bool
  mut verifying : Bool
  mut verifier_rounds : Int32
  mut prompt_variant : Int32
  mut last_stall_reason : String?
  mut last_retraction : String? // failed-verifier reason, surfaced once
  mut last_tool_fp : String?
  mut repeat_count : Int32 // consecutive identical tool-call fingerprints
  mut plan_streak : Int32 // consecutive turns with unchanged plan fingerprint
  mut prev_plan_fp : String?
  // Scope and re-entrancy guard: only events emitted by this runner's
  // current agent.run_turn belong in its budget and repetition counters.
  mut active_session_id : String?
  mut active_run_id : String?
  mut verifier : &GoalVerifier?
  mut adviser : DecisionGoalAdviser?
  mut assessment : GoalAssessment
  mut semantic_probability : Double?
  mut semantic_stall_deferrals : Int32
  mut executing_loop : Bool
  mut executing_turn : Bool
}

///|

///|
/// Default options for a goal condition: 20 turns (0 explicitly opts into unlimited), standard
/// `<goal-complete/>` / `<goal-blocked/>` markers, wrap-up at 90% of the
/// budget, stall flagging after 3 turns below 50 tokens / 3 identical tool
/// calls / 3 turns with an unchanged plan, at most 2 verifier rounds.
pub fn GoalOptions::default(goal_condition~ : String) -> GoalOptions {
  GoalOptions::{
    goal_condition,
    budget: { max_turns: 20, max_total_tokens: 0, },
    completion_marker: "<goal-complete/>",
    blocked_marker: "<goal-blocked/>",
    wrapup_ratio: 0.9,
    stall_turn_threshold: 3,
    stall_min_tokens: 50,
    completion_checklist: [],
    max_verifier_rounds: 2,
    stall_repeat_threshold: 3,
    plan_tool_name: "goal_update_plan",
    enable_semantic_advice: false,
    max_semantic_stall_deferrals: 1,
    semantic_stall_threshold: 0.75,
  }
}

///|
/// Create a GoalRunner with the given options, starting `Idle`.
///
/// # Example
/// ```mbt check
/// test "goal extension self-reports its port views" {
///   let goal = @posoco-ext-goal.goal_extension(
///     goal_condition="make the build green",
///   )
///   let manifest = goal.manifest()
///   assert_eq(manifest.id, "posoco_ext_goal")
///   assert_eq(manifest.hooks.length(), 0)
///   assert_eq(manifest.observers.length(), 1)
///   assert_eq(manifest.tools.length(), 1)
///   assert_eq(manifest.prompt_contributors.length(), 0)
///   match goal.status() {
///     Idle => ()
///     _ => fail("a fresh runner is Idle")
///   }
/// }
/// ```
pub fn GoalRunner::GoalRunner(options~ : GoalOptions) -> GoalRunner {
  GoalRunner::{
    options,
    status: Idle,
    usage: { turns: 0, total_tokens: 0, },
    history: [],
    current_turn: 0,
    last_total_tokens: 0,
    turn_output_known: false,
    turn_output_tokens: 0,
    turn_tool_count: 0,
    stall_count: 0,
    wrapup_sent: false,
    plan: GoalPlan::empty(),
    charter: "",
    charter_delivered: false,
    completion_claimed: false,
    verifying: false,
    verifier_rounds: 0,
    prompt_variant: 0,
    last_stall_reason: None,
    last_retraction: None,
    last_tool_fp: None,
    repeat_count: 0,
    plan_streak: 0,
    prev_plan_fp: None,
    active_session_id: None,
    active_run_id: None,
    verifier: None,
    adviser: None,
    assessment: Inconclusive("not assessed"),
    semantic_probability: None,
    semantic_stall_deferrals: 0,
    executing_loop: false,
    executing_turn: false,
  }
}

///|
/// Configure a fresh goal only when no run is active or paused.
pub fn GoalRunner::prepare_goal(
  self : GoalRunner,
  condition : String,
) -> Result[Unit, String] {
  let goal = condition.trim().to_owned()
  if goal == "" {
    return Err("goal must not be empty")
  }
  if self.executing_loop ||
    self.executing_turn ||
    self.status == Running ||
    self.status == Paused {
    return Err("stop the active goal before changing its objective")
  }
  self.clear()
  let next = GoalOptions::default(goal_condition=goal)
  next.enable_semantic_advice = self.options.enable_semantic_advice
  self.options = next
  Ok(())
}

///|
/// Current plan (defensive copy of the items).

///|
/// Install a verifier implementing the host's authorized acceptance policy.
/// This is the only source of a Verified outcome. No verifier means unknown.
pub fn GoalRunner::set_verifier(
  self : GoalRunner,
  verifier : &GoalVerifier,
) -> Unit {
  self.verifier = Some(verifier)
}

///|
/// The decision port is optional and advisory, never completion authority.
pub fn GoalRunner::set_decision_adviser(
  self : GoalRunner,
  decision : &@posoco.DecisionPort,
) -> Unit {
  self.adviser = Some(DecisionGoalAdviser(decision))
}

///|
pub fn GoalRunner::assessment(self : GoalRunner) -> GoalAssessment {
  self.assessment
}

///|
pub fn GoalRunner::plan(self : GoalRunner) -> GoalPlan {
  GoalPlan::{ items: self.plan.items.copy(), }
}

///|
/// JSON Schema for the plan tool arguments:
/// {"items": [{"title": string, "status": "pending"|"in_progress"|"done"}]}.
fn plan_input_schema() -> Json {
  let status_enum = Json::array([
    Json::string("pending"),
    Json::string("in_progress"),
    Json::string("done"),
  ])
  let item_schema = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            (
              "title",
              Json::object(Map::from_array([("type", Json::string("string"))])),
            ),
            (
              "status",
              Json::object(
                Map::from_array([
                  ("type", Json::string("string")),
                  ("enum", status_enum),
                ]),
              ),
            ),
          ]),
        ),
      ),
      ("required", Json::array([Json::string("title"), Json::string("status")])),
    ]),
  )
  Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            (
              "items",
              Json::object(
                Map::from_array([
                  ("type", Json::string("array")),
                  ("items", item_schema),
                ]),
              ),
            ),
          ]),
        ),
      ),
      ("required", Json::array([Json::string("items")])),
    ]),
  )
}

///|
pub impl @posoco.ToolProvider for GoalRunner with fn list_tools(self) -> Array[
  @posoco.ToolDef,
] {
  [
    @posoco.ToolDef::ToolDef(
      name=@posoco.ToolName::unchecked(self.options.plan_tool_name),
      description="Rewrite the full goal plan. Pass every item with status pending/in_progress/done; keep exactly one in_progress.",
      input_schema=plan_input_schema(),
      owner=@posoco.OwnerId::unchecked("posoco_ext_goal"),
      policy=@posoco.ExecutionPolicy::Sequential,
      provenance=Some("posoco_ext_goal"),
    ),
  ]
}

///|
pub impl @posoco.ToolProvider for GoalRunner with fn execute(
  self,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let name = ctx.name.to_string()
  if name != self.options.plan_tool_name {
    return @posoco.ToolOutcome::ToolReportedError(
      content="unknown tool",
      structured=None,
    )
  }
  // Cetas keeps the tool catalog stable for the Agent lifetime.
  // Reject non-goal invocations rather than allowing ordinary chat or
  // PlanMode to silently mutate a dormant goal's plan.
  if !self.executing_turn || self.status != Running {
    return @posoco.ToolOutcome::ToolReportedError(
      content="goal_update_plan is available only during an active goal run",
      structured=None,
    )
  }
  match GoalPlan::from_tool_args(ctx.arguments) {
    Err(msg) =>
      @posoco.ToolOutcome::ToolReportedError(content=msg, structured=None)
    Ok(parsed) => {
      let normalized = GoalPlan::normalize(parsed)
      self.plan = normalized
      let mut done = 0
      let total = normalized.items.length()
      for item in normalized.items {
        if item.status == Done {
          done = done + 1
        }
      }
      let content = "plan updated (\{done}/\{total} done)"
      let structured = Json::object(
        Map::from_array([
          ("summary", Json::string(content)),
          ("done", Json::number(done.to_double())),
          ("total", Json::number(total.to_double())),
        ]),
      )
      @posoco.ToolOutcome::Success(content~, structured=Some(structured))
    }
  }
}

///|
/// Unscoped budget accounting, applied only to events that passed the
/// scoped guard in `on_event`.
fn GoalRunner::apply_event(
  self : GoalRunner,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::ModelResponseReceived(usage~, ..) =>
      match usage {
        Some(u) => {
          match u.total_tokens {
            Some(v) => self.usage.total_tokens = self.usage.total_tokens + v
            None => ()
          }
          match u.output_tokens {
            Some(v) => {
              self.turn_output_known = true
              self.turn_output_tokens = self.turn_output_tokens + v
            }
            None => ()
          }
        }
        None => ()
      }
    @posoco.TurnEvent::TurnCompleted => self.usage.turns = self.usage.turns + 1
    @posoco.TurnEvent::ToolCallPending(call) => {
      self.turn_tool_count = self.turn_tool_count + 1
      let fp = call.name.to_string() + "|" + call.arguments.stringify()
      match self.last_tool_fp {
        Some(prev) =>
          if prev == fp {
            self.repeat_count = self.repeat_count + 1
          } else {
            self.last_tool_fp = Some(fp)
            self.repeat_count = 1
          }
        None => {
          self.last_tool_fp = Some(fp)
          self.repeat_count = 1
        }
      }
    }
    _ => ()
  }
}

///|
/// Core dispatches the scoped observer only. A GoalRunner must never
/// charge another session's turns or tool calls to its own budget.
/// The turn flag also rejects telemetry produced before or after execute.
pub impl @posoco.Observer for GoalRunner with fn on_event(
  self : GoalRunner,
  scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  if !self.executing_turn {
    return
  }
  match (scope, self.active_session_id) {
    (Some(s), Some(session)) if s.session_id.to_string() == session => {
      let run = s.run_id.to_string()
      match self.active_run_id {
        Some(expected) if expected != run => return
        None => self.active_run_id = Some(run)
        _ => ()
      }
      self.apply_event(event)
      match event {
        @posoco.TurnEvent::SessionRedirect(to~, ..) =>
          self.active_session_id = Some(to)
        _ => ()
      }
    }
    _ => ()
  }
}

///|
fn GoalRunner::is_budget_exhausted(self : GoalRunner) -> Bool {
  let b = self.options.budget
  if b.max_turns > 0 && self.current_turn >= b.max_turns {
    return true
  }
  if b.max_total_tokens > 0 && self.usage.total_tokens >= b.max_total_tokens {
    return true
  }
  false
}

///|
fn GoalRunner::near_budget_limit(self : GoalRunner) -> Bool {
  let b = self.options.budget
  let tokens_near = if b.max_total_tokens > 0 {
    let threshold = (b.max_total_tokens.to_double() * self.options.wrapup_ratio).to_int()
    self.usage.total_tokens >= threshold
  } else {
    false
  }
  let turns_near = b.max_turns > 0 && self.current_turn >= b.max_turns - 1
  tokens_near || turns_near
}

///|
/// Choose a one-shot wrap-up prompt near the budget limit, otherwise the
/// per-turn progress recitation. On the run's first working turn,
/// the recitation is prefixed with the charter; a failed-verification
/// retraction, when present, comes first of all.
fn GoalRunner::build_turn_prompt(self : GoalRunner) -> String {
  if self.charter_delivered && self.near_budget_limit() && !self.wrapup_sent {
    self.wrapup_sent = true
    return build_wrapup_prompt(
      goal_condition=self.options.goal_condition,
      plan_tool_name=self.options.plan_tool_name,
      completion_marker=self.options.completion_marker,
    )
  }
  let intro = match self.last_retraction {
    Some(r) =>
      "The previous completion claim failed verification: " + r + "\n\n"
    None => ""
  }
  self.last_retraction = None
  let charter_prefix = if self.charter_delivered {
    ""
  } else {
    self.charter + "\n\n"
  }
  self.charter_delivered = true
  intro +
  charter_prefix +
  build_progress(
    turn=self.current_turn + 1,
    max_turns=self.options.budget.max_turns,
    total_tokens=self.usage.total_tokens,
    max_total_tokens=self.options.budget.max_total_tokens,
    plan_snapshot=GoalPlan::render(self.plan),
    next_step=GoalPlan::next_step(self.plan),
    variant=self.prompt_variant,
  )
}

///|
pub fn GoalRunner::status(self : GoalRunner) -> GoalStatus {
  self.status
}

///|
/// Pause a running goal. The execute() loop will break on the next iteration.
pub fn GoalRunner::pause(self : GoalRunner) -> Unit {
  if self.status == Running {
    self.status = Paused
  }
}

///|
/// Resume a paused goal. Caller must re-call execute() to continue.
pub fn GoalRunner::resume_goal(self : GoalRunner) -> Unit {
  if self.status == Paused {
    self.status = Running
    self.last_stall_reason = None
  }
}

///|
/// Clear the goal entirely, resetting all state to Idle.
pub fn GoalRunner::clear(self : GoalRunner) -> Unit {
  // Never destroy live accounting underneath an in-flight model/tool turn.
  if self.executing_loop {
    return
  }
  self.status = Idle
  self.usage = { turns: 0, total_tokens: 0, }
  self.history = []
  self.current_turn = 0
  self.last_total_tokens = 0
  self.turn_output_known = false
  self.turn_output_tokens = 0
  self.turn_tool_count = 0
  self.stall_count = 0
  self.wrapup_sent = false
  self.plan = GoalPlan::empty()
  self.completion_claimed = false
  self.verifying = false
  self.verifier_rounds = 0
  self.prompt_variant = 0
  self.last_stall_reason = None
  self.last_retraction = None
  self.last_tool_fp = None
  self.repeat_count = 0
  self.plan_streak = 0
  self.prev_plan_fp = None
  self.charter_delivered = false
  self.charter = ""
  self.active_session_id = None
  self.active_run_id = None
  self.assessment = Inconclusive("not assessed")
  self.semantic_probability = None
  self.semantic_stall_deferrals = 0
  self.executing_turn = false
}

///|
/// Snapshot the current run without mutating the runner's state.
fn GoalRunner::result(
  self : GoalRunner,
  final_status : GoalStatus,
) -> GoalResult {
  GoalResult::{
    final_status,
    total_usage: {
      turns: self.usage.turns,
      total_tokens: self.usage.total_tokens,
    },
    turns_completed: self.current_turn,
    history: self.history.copy(),
    final_plan: GoalPlan::{ items: self.plan.items.copy(), },
    stall_reason: self.last_stall_reason,
    assessment: self.assessment,
    semantic_probability: self.semantic_probability,
  }
}

///|
/// A semantic assessment may defer *one bounded stall*, never completion,
/// permissions or budgets. Provider errors and invalid probabilities fail
/// back to deterministic pausing.
async fn GoalRunner::should_defer_stall(
  self : GoalRunner,
  reason : String,
  session_id : String,
  summary : String,
) -> Bool {
  if self.semantic_stall_deferrals >= self.options.max_semantic_stall_deferrals ||
    self.is_budget_exhausted() {
    return false
  }
  match self.adviser {
    None => false
    Some(adviser) => {
      let probability = adviser.assess_progress(
        self.options.goal_condition,
        session_id,
        reason,
        summary,
      )
      match probability {
        Some(p) if p >= self.options.semantic_stall_threshold => {
          self.semantic_stall_deferrals += 1
          self.stall_count = 0
          self.repeat_count = 0
          self.plan_streak = 0
          true
        }
        _ => false
      }
    }
  }
}

///|
/// Run the goal-driven autonomous loop.
///
/// Loops agent.run_turn() until:
/// - the model claims completion and an independent verifier provides evidence → Completed
/// - the model outputs the blocked marker → Blocked(reason)
/// - budget exhausted (turns or tokens) → BudgetExhausted
/// - the run stalls (low output, repeated identical tool calls, frozen plan) → Paused
/// - agent.run_turn() raises an error → Failed(msg)
/// - pause() called externally → Paused
pub async fn GoalRunner::execute(
  self : GoalRunner,
  agent : @posoco.Agent,
  session_id : String,
) -> GoalResult {
  if self.executing_loop {
    return self.result(Failed("goal is already executing"))
  }
  match self.status {
    Idle => {
      // Start a new run only from Idle. Resume never resets its state.
      self.clear()
      self.charter = build_charter(
        goal_condition=self.options.goal_condition,
        checklist=self.options.completion_checklist,
        completion_marker=self.options.completion_marker,
        blocked_marker=self.options.blocked_marker,
        plan_tool_name=self.options.plan_tool_name,
      )
      self.active_session_id = Some(session_id)
    }
    Paused | Running =>
      match self.active_session_id {
        Some(saved) if saved != session_id =>
          return self.result(
            Failed("cannot resume goal in a different session"),
          )
        Some(_) => ()
        None => return self.result(Failed("goal has no active session"))
      }
    _ => return self.result(self.status)
  }
  self.status = Running
  self.executing_loop = true

  while self.status == Running {
    if self.is_budget_exhausted() {
      self.status = BudgetExhausted
      break
    }

    let prompt = self.build_turn_prompt()
    self.prompt_variant = self.prompt_variant + 1
    self.current_turn = self.current_turn + 1

    let input : @posoco.Message = @posoco.Message::UserMessage(content=[
      @posoco.Content::Text(prompt),
    ])

    let current_session = match self.active_session_id {
      Some(id) => id
      None => session_id
    }
    self.turn_output_known = false
    self.turn_output_tokens = 0
    self.turn_tool_count = 0
    self.active_run_id = None
    self.executing_turn = true
    let outcome : Result[@posoco.TurnResult, String] = Ok(
      agent.run_turn(input, current_session),
    ) catch {
      e => Err(e.to_string())
    }
    self.executing_turn = false
    let turn_result = match outcome {
      Ok(r) => r
      Err(msg) => {
        self.status = Failed(msg)
        break
      }
    }

    self.active_session_id = Some(turn_result.final_session_id)
    let summary = truncate_text(text_of_message(turn_result.message), 200)
    let usage_snapshot : GoalUsage = {
      turns: self.usage.turns,
      total_tokens: self.usage.total_tokens,
    }
    self.history.push(GoalHistoryEntry::{
      turn: self.current_turn,
      usage: usage_snapshot,
      summary,
    })
    if self.status == Paused {
      // A pause requested during an in-flight turn takes effect as soon
      // as the turn settles; the completed turn remains in history.
      break
    }

    let verdict = scan_final_message(
      message=turn_result.message,
      completion_marker=self.options.completion_marker,
      blocked_marker=self.options.blocked_marker,
    )

    // The optional decision provider is invoked only when the model claims
    // completion, never on every working turn. It informs the next review;
    // it never overwrites the independent verifier's result.
    if verdict == CompletionClaimed && self.semantic_probability is None {
      match self.adviser {
        Some(adviser) => {
          let request : GoalVerificationRequest = {
            goal: self.options.goal_condition,
            criteria: self.options.completion_checklist.copy(),
            session_id: match self.active_session_id {
              Some(v) => v
              None => session_id
            },
            claim: text_of_message(turn_result.message),
          }
          self.semantic_probability = adviser.assess(request)
        }
        None => ()
      }
    }

    // The worker only submits a claim. Verification is performed directly
    // by a separate host-owned authority; another model turn repeating the
    // marker adds no proof and is never required.
    match verdict {
      CompletionClaimed => {
        self.completion_claimed = true
        if self.verifier_rounds >= self.options.max_verifier_rounds {
          self.assessment = Inconclusive(
            "independent verification budget exhausted",
          )
          self.status = Paused
          self.last_stall_reason = Some("verification budget exhausted")
          break
        }
        self.verifier_rounds += 1
        let request : GoalVerificationRequest = {
          goal: self.options.goal_condition,
          criteria: self.options.completion_checklist.copy(),
          session_id: match self.active_session_id {
            Some(v) => v
            None => session_id
          },
          claim: text_of_message(turn_result.message),
        }
        let outcome = match self.verifier {
          Some(verifier) => verifier.verify(request)
          None =>
            GoalAssessment::Inconclusive(
              "no independent GoalVerifier configured",
            )
        }
        self.assessment = outcome.validated(self.options.completion_checklist)
        match self.assessment {
          Verified(_) => {
            self.status = Completed
            break
          }
          Rejected(reason) => {
            self.last_retraction = Some(reason)
            continue
          }
          Inconclusive(_) => {
            self.status = Paused
            self.last_stall_reason = Some(
              "completion requires verified evidence",
            )
            break
          }
        }
      }
      BlockedClaimed(reason~) => {
        self.status = Blocked(reason)
        break
      }
      NoSignal => ()
    }

    // A hard resource cap takes precedence over heuristic stall handling.
    // The boundary turn has already been counted and the model did not
    // complete the goal; the next action must not be semantic deferral.
    if self.is_budget_exhausted() {
      self.status = BudgetExhausted
      break
    }

    // Stall detection: deterministic by default, with an optional,
    // bounded semantic reconsideration only after a stall is detected.
    if self.status == Running {
      if self.turn_output_known &&
        self.turn_tool_count == 0 &&
        self.turn_output_tokens < self.options.stall_min_tokens {
        self.stall_count += 1
      } else {
        self.stall_count = 0
      }
      let fp = GoalPlan::fingerprint(self.plan)
      if self.turn_tool_count > 0 {
        self.plan_streak = 0
      } else if Some(fp) == self.prev_plan_fp {
        self.plan_streak += 1
      } else {
        self.plan_streak = 1
      }
      self.prev_plan_fp = Some(fp)

      let reason : String? = if self.options.stall_turn_threshold > 0 &&
        self.stall_count >= self.options.stall_turn_threshold {
        Some("token output below threshold")
      } else if self.options.stall_repeat_threshold > 0 &&
        self.repeat_count >= self.options.stall_repeat_threshold {
        Some("repeated identical tool calls")
      } else if self.options.stall_turn_threshold > 0 &&
        self.plan_streak >= self.options.stall_turn_threshold {
        Some("plan unchanged")
      } else {
        None
      }
      match reason {
        Some(reason) => {
          let sid = match self.active_session_id {
            Some(v) => v
            None => session_id
          }
          if self.should_defer_stall(reason, sid, summary) {
            continue
          }
          self.status = Paused
          self.last_stall_reason = Some(reason)
          break
        }
        None => ()
      }
    }
    self.last_total_tokens = self.usage.total_tokens
  }

  self.executing_loop = false
  self.executing_turn = false
  self.result(self.status)
}
