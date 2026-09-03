///|
fn prompt_texts(
  template : SummaryTemplate,
  conversation : String,
  previous_summary? : String? = None,
  custom_instruction? : String? = None,
) -> (String, String) raise {
  let messages = build_summary_prompt(
    template,
    conversation,
    previous_summary~,
    custom_instruction~,
  )
  assert_eq(messages.length(), 2)
  let system = match messages[0] {
    SystemMessage(content~) => first_text(content)
    _ => fail("expected system message")
  }
  let user = match messages[1] {
    UserMessage(content~) => first_text(content)
    _ => fail("expected user message")
  }
  (system, user)
}

///|
test "prompt wraps the conversation and applies the template" {
  let (system, user) = prompt_texts(StructuredMd, "the transcript")
  assert_true(system.contains("## Goal"))
  assert_true(user.contains("<conversation>\nthe transcript\n</conversation>"))
  assert_true(user.contains("five-section"))
  assert_false(user.contains("<previous-summary>"))
  assert_false(user.contains("Additional focus:"))
}

///|
test "previous summary is anchored as its own block" {
  let (_, user) = prompt_texts(
    StructuredMd,
    "new part",
    previous_summary=Some("old summary"),
  )
  assert_true(
    user.contains("<previous-summary>\nold summary\n</previous-summary>"),
  )
  // Conversation comes first, previous summary after it.
  assert_true(user.has_prefix("<conversation>\nnew part\n</conversation>"))
}

///|
test "custom instruction becomes an additional focus line" {
  let (_, user) = prompt_texts(
    KimiXml,
    "c",
    custom_instruction=Some("keep the failing test names"),
  )
  assert_true(user.contains("Additional focus: keep the failing test names"))
  assert_true(user.contains("XML snapshot"))
}

///|
test "codex handoff template flows into both messages" {
  let (system, user) = prompt_texts(CodexHandoff, "c")
  assert_true(system.contains("handoff summary for another LLM"))
  assert_true(user.contains("<conversation>\nc\n</conversation>"))
  assert_true(
    user.contains("handoff summary described in the system instructions"),
  )
}
