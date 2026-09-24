///|
test "template enum renders its constructor name" {
  debug_inspect(SummaryTemplate::StructuredMd, content="StructuredMd")
  debug_inspect(SummaryTemplate::KimiXml, content="KimiXml")
  debug_inspect(SummaryTemplate::CodexHandoff, content="CodexHandoff")
}

///|
test "structured md template pins the five sections and rules" {
  let system = template_system_instruction(StructuredMd)
  assert_true(system.contains("## Goal"))
  assert_true(system.contains("## State"))
  assert_true(system.contains("## Key Decisions"))
  assert_true(system.contains("## Next"))
  assert_true(system.contains("## Relevant Files"))
  assert_true(system.contains("(none)"))
  assert_true(system.contains("Done / In Progress / Blocked"))
  assert_true(system.contains("verbatim"))
  assert_true(system.contains("Do not mention compaction/summarization"))
  assert_true(system.length() < 520)
}

///|
test "kimi xml template pins priorities, keep rules, and xml structure" {
  let system = template_system_instruction(KimiXml)
  assert_true(system.contains("current task"))
  assert_true(system.contains("errors/solutions"))
  assert_true(system.contains("final code"))
  assert_true(system.contains("system context"))
  assert_true(system.contains("design decisions"))
  assert_true(system.contains("TODO"))
  assert_true(system.contains("Keep errors"))
  assert_true(system.contains("merge duplicates"))
  assert_true(system.contains("drop failed attempts"))
  assert_true(system.contains("signature + key logic"))
  assert_true(system.contains("<current_focus>"))
  assert_true(system.contains("<environment>"))
  assert_true(system.contains("<completed_tasks>"))
  assert_true(system.contains("<active_issues>"))
  assert_true(system.contains("<code_state>"))
  assert_true(system.contains("<important_context>"))
  assert_true(system.length() < 700)
}

///|
test "codex handoff template is the one-paragraph minimal handoff" {
  let system = template_system_instruction(CodexHandoff)
  assert_true(system.contains("handoff for another LLM"))
  assert_true(system.contains("current progress/decisions"))
  assert_true(system.contains("constraints/preferences"))
  assert_true(system.contains("remaining next steps"))
  assert_true(system.contains("critical data, examples"))
  assert_true(system.length() < 230)
}

///|
test "user requirement is one compact non-duplicated line" {
  for template in [StructuredMd, KimiXml, CodexHandoff] {
    assert_eq(
      template_user_requirement(template),
      "Summarize now; output only the requested format.",
    )
  }
}
