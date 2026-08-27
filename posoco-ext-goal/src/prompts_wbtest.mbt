///|
/// Tests for the goal prompt builders (byte-stable contract).

///|
/// Opening tag line of a rendered envelope: the attrs snapshot target.
fn open_tag(rendered : String) -> String {
  rendered.split("\n").to_array()[0].to_owned()
}

///|
test "charter_covers_all_five_sections" {
  let charter = build_charter(
    goal_condition="make the build green",
    checklist=["write the parser", "add tests"],
    completion_marker="[goal:complete]",
    blocked_marker="[goal:blocked]",
    plan_tool_name="TodoWrite",
  )
  inspect(
    open_tag(charter),
    content="<goal-context type=\"charter\" trust=\"true\">",
  )
  // 1. envelope vocabulary: all four type values plus the NEWEST rule.
  // Body text is XML-escaped by the envelope, so quotes render as &quot;.
  assert_true(charter.contains("type=&quot;charter&quot;"))
  assert_true(charter.contains("type=&quot;progress&quot;"))
  assert_true(charter.contains("type=&quot;verification&quot;"))
  assert_true(charter.contains("type=&quot;wrapup&quot;"))
  assert_true(charter.contains("the NEWEST is current"))
  // 2. goal condition verbatim.
  assert_true(charter.contains("Goal: make the build green"))
  // 3. definition of done.
  assert_true(
    charter.contains("1. write the parser — cite evidence when you claim it"),
  )
  assert_true(
    charter.contains("2. add tests — cite evidence when you claim it"),
  )
  // 4. plan rules mention the plan tool.
  assert_true(charter.contains("Maintain your plan with the TodoWrite tool"))
  // 5. tag protocol: both markers appear.
  assert_true(charter.contains("[goal:complete] alone on the last line"))
  assert_true(charter.contains("[goal:blocked] alone on the last line"))
}

///|
test "charter_empty_checklist_falls_back_to_whole_goal_item" {
  let charter = build_charter(
    goal_condition="anything",
    checklist=[],
    completion_marker="[goal:complete]",
    blocked_marker="[goal:blocked]",
    plan_tool_name="TodoWrite",
  )
  assert_true(
    charter.contains(
      "1. the goal condition is satisfied, with evidence — cite evidence when you claim it",
    ),
  )
}

///|
test "progress_renders_turn_and_tokens_attrs_with_budgets" {
  let progress = build_progress(
    turn=4,
    max_turns=10,
    total_tokens=12300,
    max_total_tokens=100000,
    plan_snapshot="1. [x] write parser\n2. [ ] add tests",
    next_step=Some("wire the parser into main"),
    variant=0,
  )
  inspect(
    open_tag(progress),
    content="<goal-context type=\"progress\" trust=\"true\" turn=\"4/10\" tokens=\"12300/100000\">",
  )
  assert_true(progress.contains("Plan:"))
  assert_true(progress.contains("1. [x] write parser"))
  assert_true(progress.contains("NEXT STEP: wire the parser into main"))
  assert_true(progress.contains(continue_instruction(0)))
}

///|
test "progress_omits_tokens_attr_without_token_budget" {
  let progress = build_progress(
    turn=4,
    max_turns=10,
    total_tokens=12300,
    max_total_tokens=0,
    plan_snapshot="1. [ ] start",
    next_step=Some("start"),
    variant=1,
  )
  inspect(
    open_tag(progress),
    content="<goal-context type=\"progress\" trust=\"true\" turn=\"4/10\">",
  )
}

///|
test "progress_turn_attr_is_bare_without_turn_budget" {
  let progress = build_progress(
    turn=4,
    max_turns=0,
    total_tokens=12300,
    max_total_tokens=0,
    plan_snapshot="",
    next_step=None,
    variant=2,
  )
  inspect(
    open_tag(progress),
    content="<goal-context type=\"progress\" trust=\"true\" turn=\"4\">",
  )
  assert_true(
    progress.contains(
      "NEXT STEP: decompose the goal and create the initial plan",
    ),
  )
}

///|
test "continue_instruction_cycles_variants" {
  let final_sentence = "Take one concrete step toward the NEXT STEP, verify actual state before assuming prior work succeeded, then update the plan."
  inspect(
    continue_instruction(0),
    content="Continue working toward the goal. \{final_sentence}",
  )
  inspect(
    continue_instruction(1),
    content="Take the smallest step that makes the NEXT STEP item done. \{final_sentence}",
  )
  inspect(
    continue_instruction(2),
    content="Re-read the plan; if the next step is wrong, rewrite the plan first. \{final_sentence}",
  )
  inspect(
    continue_instruction(3),
    content="Continue working toward the goal. \{final_sentence}",
  )
}

///|
test "verification_prompt_lists_numbered_checklist" {
  let verification = build_verification_prompt(
    checklist=["write the parser", "add tests"],
    completion_marker="[goal:complete]",
    blocked_marker="[goal:blocked]",
  )
  inspect(
    open_tag(verification),
    content="<goal-context type=\"verification\" trust=\"true\">",
  )
  assert_true(verification.contains("Re-check every definition-of-done item"))
  assert_true(
    verification.contains(
      "[goal:complete] alone on the last line only if every item passes",
    ),
  )
  assert_true(
    verification.contains(
      "1. write the parser — cite evidence when you claim it",
    ),
  )
  assert_true(
    verification.contains("2. add tests — cite evidence when you claim it"),
  )
}

///|
test "wrapup_prompt_names_tool_and_warns_on_marker" {
  let wrapup = build_wrapup_prompt(
    goal_condition="make the build green",
    plan_tool_name="TodoWrite",
    completion_marker="[goal:complete]",
  )
  inspect(
    open_tag(wrapup),
    content="<goal-context type=\"wrapup\" trust=\"true\">",
  )
  assert_true(
    wrapup.contains("budget limit for the goal: make the build green"),
  )
  assert_true(wrapup.contains("update the plan with TodoWrite"))
  assert_true(
    wrapup.contains(
      "Do NOT output [goal:complete] unless the goal is actually finished",
    ),
  )
}

///|
test "envelope_escapes_goal_condition" {
  let charter = build_charter(
    goal_condition="fix a < b & c",
    checklist=["done"],
    completion_marker="[goal:complete]",
    blocked_marker="[goal:blocked]",
    plan_tool_name="TodoWrite",
  )
  assert_true(charter.contains("Goal: fix a &lt; b &amp; c"))
  assert_false(charter.contains("fix a < b"))
  let wrapup = build_wrapup_prompt(
    goal_condition="fix a < b & c",
    plan_tool_name="TodoWrite",
    completion_marker="[goal:complete]",
  )
  assert_true(wrapup.contains("the goal: fix a &lt; b &amp; c"))
  assert_false(wrapup.contains("fix a < b"))
}
