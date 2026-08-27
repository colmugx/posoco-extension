///|
/// Tests for the v2 line-anchored turn scanner.

///|
/// Assistant message whose whole content is one Text part.
fn asst(text : String) -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
}

///|
/// Scan with the default v2 markers.
fn scan(message : @posoco.Message) -> TurnVerdict {
  scan_final_message(
    message~,
    completion_marker="<goal-complete/>",
    blocked_marker="<goal-blocked/>",
  )
}

///|
test "exact marker line signals completion" {
  debug_inspect(
    scan(asst("working\n<goal-complete/>")),
    content="CompletionClaimed",
  )
}

///|
test "marker inline in prose is not a signal" {
  debug_inspect(scan(asst("see <goal-complete/> now")), content="NoSignal")
  debug_inspect(scan(asst("prefix<goal-blocked/>")), content="NoSignal")
}

///|
test "indented marker line still triggers after trim" {
  debug_inspect(
    scan(asst("working\n   <goal-complete/>   \n")),
    content="CompletionClaimed",
  )
}

///|
test "blocked line takes its reason from the line above" {
  debug_inspect(
    scan(asst("Need API key from user\n<goal-blocked/>")),
    content="BlockedClaimed(reason=\"Need API key from user\")",
  )
}

///|
test "reason picks the last non-empty line above the tag" {
  let msg = asst("first attempt\n\nsecond attempt failed\n   \n<goal-blocked/>")
  debug_inspect(
    scan(msg),
    content="BlockedClaimed(reason=\"second attempt failed\")",
  )
}

///|
test "reason truncates to 200 chars with ellipsis" {
  match scan(asst("\{"x".repeat(205)}\n<goal-blocked/>")) {
    BlockedClaimed(reason~) => {
      assert_eq(reason.length(), 201)
      assert_true(reason.has_suffix("…"))
    }
    other => fail("expected BlockedClaimed, got \{Repr(other)}")
  }
  // exactly 200 stays intact, no ellipsis
  let exact = "y".repeat(200)
  match scan(asst("\{exact}\n<goal-blocked/>")) {
    BlockedClaimed(reason~) => assert_eq(reason, exact)
    other => fail("expected BlockedClaimed, got \{Repr(other)}")
  }
}

///|
test "blocked without reason line above yields empty reason" {
  debug_inspect(
    scan(asst("<goal-blocked/>")),
    content="BlockedClaimed(reason=\"\")",
  )
  debug_inspect(
    scan(asst("\n\n   \n<goal-blocked/>")),
    content="BlockedClaimed(reason=\"\")",
  )
}

///|
test "last signal line wins" {
  let msg = asst("a\n<goal-complete/>\nb\nc\nd\ne\nf\n<goal-blocked/>")
  debug_inspect(scan(msg), content="BlockedClaimed(reason=\"f\")")
  let rev = asst("a\n<goal-blocked/>\nb\nc\n<goal-complete/>")
  debug_inspect(scan(rev), content="CompletionClaimed")
}

///|
test "scan is message-shape agnostic" {
  debug_inspect(
    scan(@posoco.tk_user_msg("need a key\n<goal-blocked/>")),
    content="BlockedClaimed(reason=\"need a key\")",
  )
  debug_inspect(
    scan(@posoco.tk_system_msg("all good\n<goal-complete/>")),
    content="CompletionClaimed",
  )
}

///|
test "mixed content array contributes only Text parts" {
  let msg = @posoco.Message::AssistantMessage(
    content=[
      @posoco.Content::Text("step one\n"),
      @posoco.Content::Image(media_type="image/png", data="aGk="),
      @posoco.Content::Text("step two\n<goal-complete/>"),
    ],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
  inspect(
    text_of_content([
      @posoco.Content::Text("step one\n"),
      @posoco.Content::Image(media_type="image/png", data="aGk="),
      @posoco.Content::Text("step two\n<goal-complete/>"),
    ]),
    content="step one\nstep two\n<goal-complete/>",
  )
  debug_inspect(scan(msg), content="CompletionClaimed")
}

///|
test "text_of_message variants" {
  inspect(text_of_message(@posoco.tk_system_msg("sys")), content="sys")
  inspect(
    text_of_message(
      @posoco.Message::ToolMessage(
        call_id=@posoco.CallId::unchecked("c1"),
        tool_name=@posoco.ToolName::unchecked("grep"),
        outcome=@posoco.tk_ok_result("ok"),
      ),
    ),
    content="",
  )
}
