///|
/// posoco_ext_goal — Goal-driven autonomous looping extension for Posoco.
/// Compose it like any other extension — see `goal_extension`.

///|
/// Truncate text to max_len characters, appending "…" if truncated.
fn truncate_text(text : String, max_len : Int) -> String {
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
/// Budget limits. All fields default to 0 (unlimited).
pub(all) struct GoalBudget {
  mut max_turns : Int
  mut max_total_tokens : Int
} derive(Debug)

///|
/// Accumulated usage counters, updated by the Observer impl.
pub(all) struct GoalUsage {
  mut turns : Int
  mut total_tokens : Int
} derive(Debug, Eq)

///|
/// Configuration for a goal run.
pub(all) struct GoalOptions {
  goal_condition : String
  budget : GoalBudget
  completion_marker : String // "<goal-complete/>"
  blocked_marker : String // "<goal-blocked/>"
  mut wrapup_ratio : Double // e.g. 0.9 = trigger wrap-up at 90% budget
  mut stall_turn_threshold : Int // consecutive low-output/unchanged-plan turns
  mut stall_min_tokens : Int // what counts as "low output"
  completion_checklist : Array[String] // empty = implicit whole-goal item
  mut max_verifier_rounds : Int // completion claims routed to a verifier turn
  mut stall_repeat_threshold : Int // consecutive identical tool calls
  mut plan_tool_name : String
} derive(Debug)

///|
/// One entry per completed turn in the execute loop.
pub(all) struct GoalHistoryEntry {
  turn : Int
  usage : GoalUsage
  summary : String
} derive(Eq, Debug)

///|
/// Final result returned by GoalRunner.execute().
pub(all) struct GoalResult {
  final_status : GoalStatus
  total_usage : GoalUsage
  turns_completed : Int
  history : Array[GoalHistoryEntry]
  final_plan : GoalPlan
  stall_reason : String?
} derive(Debug)

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
  options : GoalOptions
  mut status : GoalStatus
  mut usage : GoalUsage
  mut history : Array[GoalHistoryEntry]
  mut current_turn : Int
  mut last_total_tokens : Int // for delta tracking
  mut stall_count : Int // consecutive low-output turns
  mut wrapup_sent : Bool // prevent duplicate wrap-up
  mut plan : GoalPlan // replaced wholesale by the plan tool / reset
  mut charter : String // rebuilt at each execute() start from options
  mut charter_delivered : Bool // true once this run's first working turn carried the charter
  mut completion_claimed : Bool
  mut verifying : Bool
  mut verifier_rounds : Int
  mut prompt_variant : Int
  mut last_stall_reason : String?
  mut last_retraction : String? // failed-verifier reason, surfaced once
  mut last_tool_fp : String?
  mut repeat_count : Int // consecutive identical tool-call fingerprints
  mut plan_streak : Int // consecutive turns with unchanged plan fingerprint
  mut prev_plan_fp : String?
} derive(Debug)

///|
/// Default options for a goal condition: unlimited budget, standard
/// `<goal-complete/>` / `<goal-blocked/>` markers, wrap-up at 90% of the
/// budget, stall flagging after 3 turns below 50 tokens / 3 identical tool
/// calls / 3 turns with an unchanged plan, at most 2 verifier rounds.
pub fn GoalOptions::default(goal_condition~ : String) -> GoalOptions {
  GoalOptions::{
    goal_condition,
    budget: { max_turns: 0, max_total_tokens: 0 },
    completion_marker: "<goal-complete/>",
    blocked_marker: "<goal-blocked/>",
    wrapup_ratio: 0.9,
    stall_turn_threshold: 3,
    stall_min_tokens: 50,
    completion_checklist: [],
    max_verifier_rounds: 2,
    stall_repeat_threshold: 3,
    plan_tool_name: "goal_update_plan",
  }
}

///|
/// Create a GoalRunner with the given options, starting `Idle`.
///
/// # Example
/// ```mbt check
/// test "goal extension self-reports its port views" {
///   let goal = goal_extension(goal_condition="make the build green")
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
    usage: { turns: 0, total_tokens: 0 },
    history: [],
    current_turn: 0,
    last_total_tokens: 0,
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
  }
}

///|
/// Current plan (defensive copy of the items).
pub fn GoalRunner::plan(self : GoalRunner) -> GoalPlan {
  GoalPlan::{ items: self.plan.items.copy() }
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
      policy=@posoco.ExecutionPolicy::Parallel,
      provenance=Some("posoco_ext_goal"),
    ),
  ]
}

///|
pub impl @posoco.ToolProvider for GoalRunner with fn execute(
  self,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  if name != self.options.plan_tool_name {
    return @posoco.ToolOutcome::ToolReportedError(
      content="unknown tool",
      structured=None,
    )
  }
  match GoalPlan::from_tool_args(call.arguments) {
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
pub impl @posoco.Observer for GoalRunner with fn on_event(
  self,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::ModelResponseReceived(usage~, ..) =>
      match usage {
        Some(u) =>
          match u.total_tokens {
            Some(v) => self.usage.total_tokens = self.usage.total_tokens + v
            None => ()
          }
        None => ()
      }
    @posoco.TurnEvent::TurnCompleted => self.usage.turns = self.usage.turns + 1
    @posoco.TurnEvent::ToolCallPending(call) => {
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
fn GoalRunner::is_budget_exhausted(self : GoalRunner) -> Bool {
  let b = self.options.budget
  if b.max_turns > 0 && self.usage.turns >= b.max_turns {
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
  if b.max_total_tokens > 0 {
    let threshold = (b.max_total_tokens.to_double() * self.options.wrapup_ratio).to_int()
    return self.usage.total_tokens >= threshold
  }
  if b.max_turns > 0 {
    return self.current_turn >= b.max_turns - 1
  }
  false
}

///|
/// Choose this iteration's turn input: a verification prompt while a
/// completion claim is being checked, a one-shot wrap-up prompt near the
/// budget limit, otherwise the per-turn progress recitation. On the run's
/// first working turn (verifier and wrap-up turns are not working turns),
/// the recitation is prefixed with the charter; a failed-verification
/// retraction, when present, comes first of all.
fn GoalRunner::build_turn_prompt(self : GoalRunner) -> String {
  if self.verifying {
    return build_verification_prompt(
      checklist=self.options.completion_checklist,
      completion_marker=self.options.completion_marker,
      blocked_marker=self.options.blocked_marker,
    )
  }
  if self.near_budget_limit() && !self.wrapup_sent {
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
/// Get the current goal status.
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
  }
}

///|
/// Clear the goal entirely, resetting all state to Idle.
pub fn GoalRunner::clear(self : GoalRunner) -> Unit {
  self.status = Idle
  self.usage = { turns: 0, total_tokens: 0 }
  self.history = []
  self.current_turn = 0
  self.last_total_tokens = 0
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
}

///|
/// Run the goal-driven autonomous loop.
///
/// Loops agent.run_turn() until:
/// - the model outputs the completion marker and a verifier turn confirms → Completed
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
  self.status = Running
  self.usage = { turns: 0, total_tokens: 0 }
  self.history = []
  self.wrapup_sent = false
  self.current_turn = 0
  self.last_total_tokens = 0
  self.stall_count = 0
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
  self.plan = GoalPlan::empty()
  self.charter = build_charter(
    goal_condition=self.options.goal_condition,
    checklist=self.options.completion_checklist,
    completion_marker=self.options.completion_marker,
    blocked_marker=self.options.blocked_marker,
    plan_tool_name=self.options.plan_tool_name,
  )
  self.charter_delivered = false

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

    let outcome : Result[@posoco.TurnResult, String] = Ok(
      agent.run_turn(input, session_id),
    ) catch {
      e => Err(e.to_string())
    }
    let turn_result = match outcome {
      Ok(r) => r
      Err(msg) => {
        self.status = Failed(msg)
        break
      }
    }

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

    let verdict = scan_final_message(
      message=turn_result.message,
      completion_marker=self.options.completion_marker,
      blocked_marker=self.options.blocked_marker,
    )

    // Gate: route completion/blocked claims through the verifier protocol.
    match verdict {
      CompletionClaimed => {
        self.completion_claimed = true
        if self.verifying {
          self.verifying = false
          self.status = Completed
          break
        } else if self.verifier_rounds >= self.options.max_verifier_rounds {
          self.status = Blocked("verification budget exhausted")
          break
        } else {
          self.verifier_rounds = self.verifier_rounds + 1
          self.verifying = true
          continue
        }
      }
      BlockedClaimed(reason~) =>
        if self.verifying {
          // Verifier rejected the claim: retract and go back to work.
          self.verifying = false
          self.last_retraction = Some(reason)
          continue
        } else {
          self.status = Blocked(reason)
          break
        }
      NoSignal =>
        // Ambiguous verifier answer: back to work, fall through to stall checks.
        if self.verifying {
          self.verifying = false
        }
    }

    // Stall detection: only on work turns that did not end the run.
    if self.status == Running && !self.verifying {
      let delta = self.usage.total_tokens - self.last_total_tokens
      if delta < self.options.stall_min_tokens {
        self.stall_count = self.stall_count + 1
      } else {
        self.stall_count = 0
      }
      if self.stall_count >= self.options.stall_turn_threshold {
        self.status = Paused
        self.last_stall_reason = Some("token output below threshold")
        break
      }
      if self.repeat_count >= self.options.stall_repeat_threshold {
        self.status = Paused
        self.last_stall_reason = Some("repeated identical tool calls")
        break
      }
      let fp = GoalPlan::fingerprint(self.plan)
      if Some(fp) == self.prev_plan_fp {
        self.plan_streak = self.plan_streak + 1
      } else {
        self.plan_streak = 1
        self.prev_plan_fp = Some(fp)
      }
      if self.plan_streak >= self.options.stall_turn_threshold {
        self.status = Paused
        self.last_stall_reason = Some("plan unchanged")
        break
      }
    }
    self.last_total_tokens = self.usage.total_tokens
  }

  GoalResult::{
    final_status: self.status,
    total_usage: {
      turns: self.usage.turns,
      total_tokens: self.usage.total_tokens,
    },
    turns_completed: self.current_turn,
    history: self.history.copy(),
    final_plan: GoalPlan::{ items: self.plan.items.copy() },
    stall_reason: self.last_stall_reason,
  }
}
