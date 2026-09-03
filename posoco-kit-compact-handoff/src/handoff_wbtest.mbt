// handoff_wbtest.mbt — NewThread handoff contract tests.

///|
fn handoff_body(result : @posoco.CompactResult) -> String raise {
  match result.compacted_messages[0] {
    @posoco.Message::UserMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(body) => body
        _ => fail("handoff message must open with a Text block")
      }
    _ => fail("handoff message must be a UserMessage")
  }
}

///|
test "result mode is NewThread and tail is empty without tail messages" {
  let result = build_handoff_result("s", [], "/p")
  inspect(result.mode, content="NewThread")
  assert_eq(result.compacted_messages.length(), 1)
}

///|
test "body contains prefix, summary, parent path and default hint as substrings" {
  let result = build_handoff_result(
    "Implemented CK-04; all tests pass.",
    [],
    "/tmp/sessions/old_session",
  )
  let body = handoff_body(result)
  assert_true(body.contains(HANDOFF_PREFIX))
  assert_true(body.contains("Implemented CK-04; all tests pass."))
  assert_true(
    body.contains(
      "Previous session transcript (searchable): /tmp/sessions/old_session",
    ),
  )
  assert_true(body.contains(default_retrieval_hint()))
}

///|
test "default_retrieval_hint contains the mandated search instruction" {
  assert_true(
    default_retrieval_hint().contains(
      "You can search the old session file (e.g. with grep/read) to recover the full context.",
    ),
  )
}

///|
test "custom retrieval_hint overrides the default" {
  let result = build_handoff_result(
    "s",
    [],
    "/p",
    retrieval_hint="custom hint text",
  )
  let body = handoff_body(result)
  assert_true(body.contains("custom hint text"))
  assert_true(!body.contains(default_retrieval_hint()))
}

///|
test "tail messages are preserved verbatim and in order" {
  let tail : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("first tail")]),
    @posoco.Message::AssistantMessage(
      content=[@posoco.Content::Text("second tail")],
      tool_calls=[],
      reasoning=None,
      finish_reason=@posoco.FinishReason::Stop,
    ),
  ]
  let result = build_handoff_result("s", tail, "/p")
  assert_eq(result.compacted_messages.length(), 3)
  assert_true(result.compacted_messages[1] == tail[0])
  assert_true(result.compacted_messages[2] == tail[1])
  assert_eq(tail.length(), 2)
}

///|
test "out-of-range tail_turns falls back to the default result" {
  let tail : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("kept")]),
  ]
  let baseline = build_handoff_result("s", tail, "/p")
  assert_true(build_handoff_result("s", tail, "/p", tail_turns=0) == baseline)
  assert_true(build_handoff_result("s", tail, "/p", tail_turns=21) == baseline)
  assert_true(build_handoff_result("s", tail, "/p", tail_turns=20) == baseline)
  assert_true(build_handoff_result("s", tail, "/p", tail_turns=1) == baseline)
}

///|
test "empty summary still yields a well-formed handoff" {
  let result = build_handoff_result("", [], "/p")
  inspect(result.mode, content="NewThread")
  let body = handoff_body(result)
  assert_true(body.contains(HANDOFF_PREFIX))
  assert_true(body.contains("Previous session transcript (searchable): /p"))
  assert_true(body.contains(default_retrieval_hint()))
}

///|
test "handoff_session_path joins and collapses duplicate slashes" {
  inspect(handoff_session_path("sessions", "abc"), content="sessions/abc")
  inspect(handoff_session_path("sessions/", "abc"), content="sessions/abc")
  inspect(handoff_session_path("sessions//", "abc"), content="sessions/abc")
  inspect(handoff_session_path("sessions/", "/abc"), content="sessions/abc")
}
