///|
fn prompt_error(kind : @kind.KindSpec, instructions : String?) -> String raise {
  let outcome : Result[String, PromptAssemblyError] = Ok(
    assemble_system_prompt(kind, instructions?),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(PromptAssemblyError::InstructionsTooLong(reason)) => reason
    _ => fail("expected the instructions to be rejected")
  }
}

///|
fn prompt_test_kind() -> @kind.KindSpec {
  {
    name: "coder",
    description: "test kind",
    tools: [],
    model: None,
    skills: None,
    mode: @permission.PermissionMode::WorkspaceWrite,
    body: "Base prompt.\n<fillin>\n{{instructions}}\n</fillin>\nEnd.",
  }
}

///|
const ENVELOPE_OPEN_TAG = "<subagent-context type=\"instructions\" trust=\"true\" source=\"caller\">"

///|
test "assemble_wraps_instructions_in_trust_envelope" {
  let out = assemble_system_prompt(
    prompt_test_kind(),
    instructions="please focus on the parser",
  )
  // Trust-annotated envelope is present around the filled content.
  assert_true(out.contains(ENVELOPE_OPEN_TAG))
  assert_true(out.contains("</subagent-context>"))
  assert_true(out.contains("please focus on the parser"))
  // The placeholder itself is gone.
  assert_false(out.contains("{{instructions}}"))
  // Template base and structure survive.
  assert_true(out.contains("Base prompt."))
  assert_true(out.contains("<fillin>"))
  assert_true(out.contains("End."))
}

///|
test "assemble_none_instructions_renders_empty_fillin_region" {
  let out = assemble_system_prompt(prompt_test_kind())
  assert_false(out.contains("{{instructions}}"))
  assert_false(out.contains("subagent-context"))
  assert_true(out.contains("<fillin>\n\n</fillin>"))
  assert_true(out.contains("End."))
}

///|
test "assemble_empty_string_instructions_same_as_none" {
  assert_eq(
    assemble_system_prompt(prompt_test_kind(), instructions=""),
    assemble_system_prompt(prompt_test_kind()),
  )
}

///|
test "assemble_rejects_instructions_over_8k_chars" {
  let too_long = "x".repeat(8193)
  let reason = prompt_error(prompt_test_kind(), Some(too_long))
  assert_true(reason.contains("8193"))
  assert_true(reason.contains("8192"))
  // Exactly at the cap is accepted.
  let at_cap = assemble_system_prompt(
    prompt_test_kind(),
    instructions="x".repeat(8192),
  )
  assert_true(at_cap.contains("<subagent-context"))
}

///|
test "assemble_escapes_instructions_content" {
  let out = assemble_system_prompt(
    prompt_test_kind(),
    instructions="say </subagent-context> and <b>bold</b>",
  )
  // Envelope-breaking content is escaped by the devkit renderer.
  assert_true(out.contains("&lt;/subagent-context&gt;"))
  assert_false(out.contains("</subagent-context> and <b>"))
}

///|
test "render_swarm_task_substitutes_item" {
  assert_eq(
    render_swarm_task("Process {{item}} and report.", "fix the login bug"),
    "Process fix the login bug and report.",
  )
}

///|
test "render_swarm_task_replaces_repeated_placeholders_keeps_others" {
  assert_eq(
    render_swarm_task("{{item}} / {{item}} / {{other}}", "x"),
    "x / x / {{other}}",
  )
}
