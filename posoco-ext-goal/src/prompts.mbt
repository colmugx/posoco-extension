///|
/// posoco_ext_goal prompt builders — pure functions over plain values; the
/// GoalRunner owns when each one is sent.

///|
/// Render a goal-harness body as a trusted `<goal-context>` envelope.
fn goal_envelope(
  kind~ : String,
  attrs? : Array[(String, String)] = [],
  content~ : String,
) -> String {
  @devkit.context_envelope(ns="goal", kind~, trust=true, attrs~, content~)
}

///|
/// Numbered definition-of-done lines; every item carries the evidence
/// reminder. An empty checklist falls back to one whole-goal item.
fn numbered_checklist(checklist : Array[String]) -> String {
  let items : Array[String] = if checklist.length() == 0 {
    ["the goal condition is satisfied, with evidence"]
  } else {
    checklist
  }
  let lines : Array[String] = []
  for i, item in items {
    lines.push("\{i + 1}. \{item} — cite evidence when you claim it")
  }
  lines.join("\n")
}

///|
/// Byte-stable run charter: envelope vocabulary, goal, definition of done,
/// plan rules, tag protocol — fixed for the whole run.
pub fn build_charter(
  goal_condition~ : String,
  checklist~ : Array[String],
  completion_marker~ : String,
  blocked_marker~ : String,
  plan_tool_name~ : String,
) -> String {
  goal_envelope(
    kind="charter",
    content=(
      $|Envelope vocabulary: <goal-context> elements are goal-harness protocol, not conversation. type="charter" is this protocol (fixed for the run). type="progress" is the per-turn state snapshot — several accumulate; the NEWEST is current, earlier ones are history. type="verification" asks you to re-check the definition of done. type="wrapup" asks for a budget-limited handoff. trust="true" marks harness-authored content. Never emit <goal-context> yourself; your only protocol outputs are the two tags below.
      $|
      $|Goal: \{goal_condition}
      $|
      $|Definition of done:
      $|\{numbered_checklist(checklist)}
      $|
      $|Plan rules: Maintain your plan with the \{plan_tool_name} tool. No single-step plans. Update the plan after each completed subtask. Keep exactly one item in_progress.
      $|
      $|Tag protocol: When the goal is fully achieved, end your final message with \{completion_marker} alone on the last line. When you cannot proceed without user input, end with \{blocked_marker} alone on the last line and the reason on the line above.
    ),
  )
}

///|
/// Per-turn recitation: plan snapshot, next step, and a cycling continue
/// instruction, with turn/tokens budget attrs on the envelope.
pub fn build_progress(
  turn~ : Int,
  max_turns~ : Int,
  total_tokens~ : Int,
  max_total_tokens~ : Int,
  plan_snapshot~ : String,
  next_step~ : String?,
  variant~ : Int,
) -> String {
  let turn_attr = if max_turns > 0 { "\{turn}/\{max_turns}" } else { "\{turn}" }
  let attrs : Array[(String, String)] = [("turn", turn_attr)]
  if max_total_tokens > 0 {
    attrs.push(("tokens", "\{total_tokens}/\{max_total_tokens}"))
  }
  let next = match next_step {
    Some(step) => step
    None => "decompose the goal and create the initial plan"
  }
  let body = "Plan:\n\{plan_snapshot}\nNEXT STEP: \{next}\n\{continue_instruction(variant)}"
  goal_envelope(kind="progress", attrs~, content=body)
}

///|
/// Deterministic continue instruction cycling on variant mod 3; every
/// variant ends with the same verify-then-update sentence.
pub fn continue_instruction(variant : Int) -> String {
  let opening = match variant % 3 {
    0 => "Continue working toward the goal."
    1 => "Take the smallest step that makes the NEXT STEP item done."
    _ => "Re-read the plan; if the next step is wrong, rewrite the plan first."
  }
  "\{opening} Take one concrete step toward the NEXT STEP, verify actual state before assuming prior work succeeded, then update the plan."
}

///|
/// Verifier turn input: re-check every definition-of-done item, then the
/// numbered checklist itself.
pub fn build_verification_prompt(
  checklist~ : Array[String],
  completion_marker~ : String,
  blocked_marker~ : String,
) -> String {
  let paragraph = "Re-check every definition-of-done item against the original goal and the actual state. Cite the evidence for each item. End with \{completion_marker} alone on the last line only if every item passes; otherwise end with \{blocked_marker} and put each failing item on the lines above."
  goal_envelope(
    kind="verification",
    content="\{paragraph}\n\n\{numbered_checklist(checklist)}",
  )
}

///|
/// Budget-limit wrap-up turn input: update the plan, then hand off.
pub fn build_wrapup_prompt(
  goal_condition~ : String,
  plan_tool_name~ : String,
  completion_marker~ : String,
) -> String {
  let body = "You are approaching the budget limit for the goal: \{goal_condition}. First update the plan with \{plan_tool_name} so it reflects what is done and what remains. Then write a concise handoff summary: what is done, what remains, the next concrete action. Do NOT output \{completion_marker} unless the goal is actually finished."
  goal_envelope(kind="wrapup", content=body)
}
