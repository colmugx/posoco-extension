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
  assert_true(
    system.contains(
      "Do not mention that a compaction or summarization happened",
    ),
  )
}

///|
test "kimi xml template pins priorities, keep rules, and xml structure" {
  let system = template_system_instruction(KimiXml)
  assert_true(system.contains("Current Task State"))
  assert_true(system.contains("Errors & Solutions"))
  assert_true(system.contains("Code Evolution"))
  assert_true(system.contains("System Context"))
  assert_true(system.contains("Design Decisions"))
  assert_true(system.contains("TODO"))
  assert_true(system.contains("MUST KEEP"))
  assert_true(system.contains("MERGE"))
  assert_true(system.contains("REMOVE"))
  assert_true(system.contains("CONDENSE"))
  assert_true(system.contains("<current_focus>"))
  assert_true(system.contains("<environment>"))
  assert_true(system.contains("<completed_tasks>"))
  assert_true(system.contains("<active_issues>"))
  assert_true(system.contains("<code_state>"))
  assert_true(system.contains("<important_context>"))
}

///|
test "codex handoff template is the one-paragraph minimal handoff" {
  let system = template_system_instruction(CodexHandoff)
  assert_true(system.contains("handoff summary for another LLM"))
  assert_true(system.contains("current progress and key decisions"))
  assert_true(system.contains("constraints, or user preferences"))
  assert_true(system.contains("what remains to be done"))
  assert_true(system.contains("critical data, examples, or references"))
  assert_true(system.contains("Be concise, structured"))
}

///|
test "each template has its own user requirement line" {
  assert_true(template_user_requirement(StructuredMd).contains("five-section"))
  assert_true(template_user_requirement(KimiXml).contains("XML snapshot"))
  assert_true(
    template_user_requirement(CodexHandoff).contains("handoff summary"),
  )
}
