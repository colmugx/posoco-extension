///|
/// Context-budget state used by the continuity planner.
pub(all) enum BudgetState {
  Normal
  Prepare
  CheckpointNeeded
  Emergency
} derive(Eq, Debug)

///|
/// Structured representation of settled work. A checkpoint is a compact
/// working record, not authoritative historical evidence.
pub(all) struct CheckpointSummary {
  goal : String
  completed : Array[String]
  decisions : Array[String]
  artifacts : Array[String]
  facts : Array[String]
  open_threads : Array[String]
} derive(Eq, Debug)

///|
pub(all) struct BudgetReport {
  estimated_tokens : Int
  context_window : Int
  usage_ratio : Double
  state : BudgetState
} derive(Eq, Debug)

///|
/// Estimate tokens from character count. This intentionally stays provider
/// neutral; products may replace it with a tokenizer-aware estimator later.
pub fn estimate_text_tokens(text : String) -> Int {
  if text.length() == 0 {
    0
  } else {
    (text.length() + 3) / 4
  }
}

///|
pub fn classify_budget(
  estimated_tokens : Int,
  context_window : Int,
  config : ContinuityConfig,
) -> BudgetReport {
  if context_window <= 0 {
    return {
      estimated_tokens,
      context_window,
      usage_ratio: 0.0,
      state: Normal,
    }
  }
  let ratio = estimated_tokens.to_double() / context_window.to_double()
  let state = if ratio >= config.emergency_ratio {
    Emergency
  } else if ratio >= config.checkpoint_ratio {
    CheckpointNeeded
  } else if ratio >= config.prepare_ratio {
    Prepare
  } else {
    Normal
  }
  { estimated_tokens, context_window, usage_ratio: ratio, state }
}

///|
/// Minimal validation for model-produced checkpoint content.
pub fn CheckpointSummary::is_meaningful(self : CheckpointSummary) -> Bool {
  if self.goal.trim() == "" {
    return false
  }
  self.completed.length() > 0 ||
  self.decisions.length() > 0 ||
  self.artifacts.length() > 0 ||
  self.facts.length() > 0 ||
  self.open_threads.length() > 0
}

fn render_items(title : String, items : Array[String]) -> String {
  if items.length() == 0 {
    return ""
  }
  let lines : Array[String] = []
  lines.push(title + ":")
  for item in items {
    lines.push("- " + item)
  }
  lines.join("\n") + "\n\n"
}

///|
/// Render a checkpoint as a system-owned historical representation.
pub fn CheckpointSummary::render(
  self : CheckpointSummary,
  checkpoint_id : String,
) -> String {
  let out : Array[String] = []
  out.push("<session-checkpoint id=\"" + checkpoint_id + "\">")
  out.push("Goal:\n" + self.goal + "\n")
  let completed = render_items("Completed", self.completed)
  if completed != "" { out.push(completed) }
  let decisions = render_items("Decisions", self.decisions)
  if decisions != "" { out.push(decisions) }
  let artifacts = render_items("Artifacts", self.artifacts)
  if artifacts != "" { out.push(artifacts) }
  let facts = render_items("Exact facts", self.facts)
  if facts != "" { out.push(facts) }
  let open_threads = render_items("Open threads", self.open_threads)
  if open_threads != "" { out.push(open_threads) }
  out.push(
    "This is a compact representation of earlier session history. " +
    "Use session_history_search/read when exact historical details matter."
  )
  out.push("</session-checkpoint>")
  out.join("\n")
}
