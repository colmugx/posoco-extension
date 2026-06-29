///|
/// posoco_ext_goal — Goal-driven autonomous looping extension for Posoco.
///
/// Implements PipelineHook (inject goal context, detect completion markers)
/// and Observer (track token usage). The execute() method provides the
/// external orchestration loop that calls agent.run_turn() until the goal
/// is achieved, blocked, or the budget is exhausted.
///
/// Usage:
///   let runner = GoalRunner::new(default_options("fix all tests"))
///   let agent = Agent::new(model, hooks=[runner], observers=[runner], ...)
///   let result = runner.execute(agent, "session_1")

// ── Helpers ────────────────────────────────────────────────────────────────

///|
/// Extract plain text from a Content array.
fn extract_text(content : Array[@posoco.Content]) -> String {
  let parts : Array[String] = []
  for c in content {
    match c {
      @posoco.Content::Text(t) => parts.push(t)
      _ => ()
    }
  }
  parts.join("")
}

///|
/// Extract the reason preceding a [goal:blocked] marker.
/// Looks for the marker and returns the last non-empty line before it.
fn extract_block_reason(text : String, marker : String) -> String {
  let idx = text.find(marker)
  match idx {
    Some(pos) => {
      let before = text[0:pos].trim()
      let lines = before.split("\n").to_array()
      // Walk backwards to find last non-empty line
      let mut last_line = ""
      let mut i = lines.length() - 1
      while i >= 0 && last_line == "" {
        let trimmed = lines[i].trim()
        if trimmed != "" {
          last_line = trimmed.to_owned()
        }
        i = i - 1
      }
      if last_line.length() > 200 {
        last_line[0:200].to_owned() + "…"
      } else {
        last_line
      }
    }
    None => ""
  }
}

///|
/// Truncate text to max_len characters, appending "…" if truncated.
fn truncate_text(text : String, max_len : Int) -> String {
  if text.length() > max_len {
    text[0:max_len].to_owned() + "…"
  } else {
    text
  }
}

// ── Types ──────────────────────────────────────────────────────────────────

///|
pub(all) enum GoalStatus {
  Idle // No goal set
  Running // Actively pursuing a goal
  Paused // Goal paused by user
  Completed // Goal condition satisfied
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
  completion_marker : String // "[goal:complete]"
  blocked_marker : String // "[goal:blocked]"
  mut wrapup_ratio : Double // e.g. 0.9 = trigger wrap-up at 90% budget
  mut stall_turn_threshold : Int // consecutive low-output turns before flagging
  mut stall_min_tokens : Int // what counts as "low output"
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
} derive(Debug)

// ── GoalRunner ─────────────────────────────────────────────────────────────

///|
/// Central struct: implements PipelineHook + Observer + provides execute() loop.
///
/// Pass the same instance to both hooks=[] and observers=[] in Agent::new.
/// Mutable state is shared between the two trait objects.
pub(all) struct GoalRunner {
  options : GoalOptions
  mut status : GoalStatus
  mut usage : GoalUsage
  mut history : Array[GoalHistoryEntry]
  mut current_turn : Int
  mut last_total_tokens : Int // for delta tracking
  mut stall_count : Int // consecutive low-output turns
  mut wrapup_sent : Bool // prevent duplicate wrap-up
} derive(Debug)

///|
/// Create default options with unlimited budget.
pub fn default_options(goal_condition : String) -> GoalOptions {
  GoalOptions::{
    goal_condition,
    budget: { max_turns: 0, max_total_tokens: 0 },
    completion_marker: "[goal:complete]",
    blocked_marker: "[goal:blocked]",
    wrapup_ratio: 0.9,
    stall_turn_threshold: 3,
    stall_min_tokens: 50,
  }
}

///|
/// Create a GoalRunner with the given options.
pub fn GoalRunner::new(options : GoalOptions) -> GoalRunner {
  GoalRunner::{
    options,
    status: Idle,
    usage: { turns: 0, total_tokens: 0 },
    history: [],
    current_turn: 0,
    last_total_tokens: 0,
    stall_count: 0,
    wrapup_sent: false,
  }
}

// ── PipelineHook impl ──────────────────────────────────────────────────────

///|
/// Build the goal system prompt injected at BeforeModel.
fn build_goal_system_prompt(runner : GoalRunner) -> String {
  let budget_line = if runner.options.budget.max_turns > 0 {
    "Turn budget: \{runner.current_turn}/\{runner.options.budget.max_turns}\n"
  } else {
    ""
  }
  let token_line = if runner.options.budget.max_total_tokens > 0 {
    "Token budget: \{runner.usage.total_tokens}/\{runner.options.budget.max_total_tokens}\n"
  } else {
    ""
  }
  let goal = runner.options.goal_condition
  let marker = runner.options.completion_marker
  let blocked = runner.options.blocked_marker
  "[GOAL CONTEXT]\nGoal: \{goal}\n\{budget_line}\{token_line}Output \{marker} when the goal is fully achieved.\nOutput \{blocked} with a reason if you cannot proceed without user input."
}

///|
pub impl @posoco.PipelineHook for GoalRunner with fn on_stage(
  self,
  stage : @posoco.Stage,
) -> Result[@posoco.Stage, @posoco.HookError] {
  match stage {
    // Inject goal context as a system message before the model call
    @posoco.Stage::BeforeModel(msgs) => {
      if self.status != Running {
        return Ok(stage)
      }
      let sys_text = build_goal_system_prompt(self)
      let sys_msg : @posoco.Message = {
        role: @posoco.Role::System,
        content: [@posoco.Content::Text(sys_text)],
        tool_calls: [],
        tool_call_id: None,
        name: None,
      }
      let new_msgs = [sys_msg]
      for m in msgs {
        new_msgs.push(m)
      }
      Ok(@posoco.Stage::BeforeModel(new_msgs))
    }
    // Detect completion / blocked markers in model response
    @posoco.Stage::AfterModel(resp) => {
      if self.status != Running {
        return Ok(stage)
      }
      let text = extract_text(resp.message.content)
      if text.contains(self.options.completion_marker) {
        self.status = Completed
      } else if text.contains(self.options.blocked_marker) {
        self.status = Blocked(
          extract_block_reason(text, self.options.blocked_marker),
        )
      }
      Ok(stage)
    }
    _ => Ok(stage)
  }
}

// ── Observer impl ──────────────────────────────────────────────────────────

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
    _ => ()
  }
}

// ── Budget helpers ─────────────────────────────────────────────────────────

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

// ── Prompt formatting ──────────────────────────────────────────────────────

///|
fn GoalRunner::format_continue_prompt(self : GoalRunner) -> String {
  let goal = self.options.goal_condition
  let marker = self.options.completion_marker
  let blocked = self.options.blocked_marker
  "Continue working toward the goal: \{goal}\n\nTake the next concrete step. Verify actual state before assuming prior work succeeded.\n\nEnd with \{marker} when fully done, or \{blocked} if you need user input."
}

///|
fn GoalRunner::format_wrapup_prompt(self : GoalRunner) -> String {
  let goal = self.options.goal_condition
  let marker = self.options.completion_marker
  "You are approaching the token budget limit for goal: \{goal}\n\nFinish the current step if it is small and safe. Then write a concise handoff summary:\n- What is done\n- What remains\n- The next concrete action to take\n\nDo NOT output \{marker} unless the goal is actually finished."
}

// ── Public query/control methods ───────────────────────────────────────────

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
}

// ── execute() loop ─────────────────────────────────────────────────────────

///|
/// Run the goal-driven autonomous loop.
///
/// Loops agent.run_turn() until:
/// - PipelineHook detects [goal:complete] → Completed
/// - PipelineHook detects [goal:blocked] → Blocked(reason)
/// - Budget exhausted (turns or tokens) → BudgetExhausted
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

  while self.status == Running {
    // 1. Check budget
    if self.is_budget_exhausted() {
      self.status = BudgetExhausted
      break
    }

    // 2. Build prompt
    let prompt = if self.near_budget_limit() && !self.wrapup_sent {
      self.wrapup_sent = true
      self.format_wrapup_prompt()
    } else {
      self.format_continue_prompt()
    }

    self.current_turn = self.current_turn + 1

    // 3. Create user message
    let input : @posoco.Message = {
      role: @posoco.Role::User,
      content: [@posoco.Content::Text(prompt)],
      tool_calls: [],
      tool_call_id: None,
      name: None,
    }

    // 4. Execute one turn
    let turn_result = agent.run_turn(input, session_id) catch {
      e => {
        self.status = Failed(e.to_string())
        break
      }
    }

    // 5. Record history
    let summary = truncate_text(extract_text(turn_result.message.content), 200)
    let usage_snapshot : GoalUsage = {
      turns: self.usage.turns,
      total_tokens: self.usage.total_tokens,
    }
    self.history.push(GoalHistoryEntry::{
      turn: self.current_turn,
      usage: usage_snapshot,
      summary,
    })

    // 6. Stall detection: only if PipelineHook didn't set a terminal status
    if self.status == Running {
      let token_delta = self.usage.total_tokens - self.last_total_tokens
      if token_delta < self.options.stall_min_tokens {
        self.stall_count = self.stall_count + 1
        if self.stall_count >= self.options.stall_turn_threshold {
          self.status = Paused
          break
        }
      } else {
        self.stall_count = 0
      }
    }
    self.last_total_tokens = self.usage.total_tokens

    // Note: PipelineHook's AfterModel may have set status to
    // Completed or Blocked during agent.run_turn(). The while
    // condition will catch this on the next iteration.
  }

  GoalResult::{
    final_status: self.status,
    total_usage: {
      turns: self.usage.turns,
      total_tokens: self.usage.total_tokens,
    },
    turns_completed: self.current_turn,
    history: self.history.copy(),
  }
}
