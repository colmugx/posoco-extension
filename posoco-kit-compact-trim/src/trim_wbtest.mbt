///|
/// trim_wbtest.mbt — behavior coverage for trim_fallback / estimate_tokens.
/// Token math in these tests is hand-computed with the additive
/// per-message ceil(chars/4) estimator; text fixtures are n repetitions
/// of "x" so char counts are exact.

///|
fn tx(n : Int) -> String {
  let buf = StringBuilder()
  for _ in 0..<n {
    buf.write_string("x")
  }
  buf.to_string()
}

///|
fn tw_system(chars : Int) -> @posoco.Message {
  @posoco.Message::SystemMessage(content=[@posoco.Content::Text(tx(chars))])
}

///|
fn tw_user(chars : Int) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(tx(chars))])
}

///|
fn tw_user_image(media_type : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[
    @posoco.Content::Image(media_type~, data=""),
  ])
}

///|
fn tw_assistant(chars : Int) -> @posoco.Message {
  let no_reasoning : @posoco.Reasoning? = None
  @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text(tx(chars))],
    tool_calls=[],
    reasoning=no_reasoning,
    finish_reason=@posoco.FinishReason::Stop,
  )
}

///|
fn tw_assistant_call(name : String) -> @posoco.Message {
  let no_reasoning : @posoco.Reasoning? = None
  @posoco.Message::AssistantMessage(
    content=[],
    tool_calls=[
      @posoco.ToolCall::{
        call_id: @posoco.CallId::unchecked("call-1"),
        name: @posoco.ToolName::unchecked(name),
        arguments: Json::null(),
      },
    ],
    reasoning=no_reasoning,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
}

///|
fn tw_tool(chars : Int) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call-1"),
    tool_name=@posoco.ToolName::unchecked("bash"),
    outcome=@posoco.ToolOutcome::Success(content=tx(chars), structured=None),
  )
}

///|
fn tw_role(message : @posoco.Message) -> String {
  match message {
    SystemMessage(..) => "S"
    UserMessage(..) => "U"
    AssistantMessage(..) => "A"
    ToolMessage(..) => "T"
  }
}

///|
fn tw_tags(messages : Array[@posoco.Message]) -> String {
  messages.map(tw_role).join("")
}

///|
test "trim/estimate tokens: ceil per message and additive" {
  inspect(estimate_tokens([tw_user(4)]), content="1")
  inspect(estimate_tokens([tw_user(5)]), content="2")
  inspect(estimate_tokens([tw_user(0)]), content="0")
  // tool call name (9) + arguments "null" (4) = 13 chars -> 4 tokens
  inspect(estimate_tokens([tw_assistant_call("read_file")]), content="4")
  // image counts only its media_type string: 9 chars -> 3 tokens
  inspect(estimate_tokens([tw_user_image("image/png")]), content="3")
  // tool message counts the output content only, not the tool name
  inspect(estimate_tokens([tw_tool(8)]), content="2")
  // per-message ceil is additive: 1 + 1 = 2, not ceil(2/4) = 1
  inspect(estimate_tokens([tw_user(1), tw_user(1)]), content="2")
}

///|
test "trim/empty input" {
  guard trim_fallback([], 100) is Err(TrimError::EmptyInput) else {
    fail("expected EmptyInput")
  }
}

///|
test "trim/already within budget" {
  let messages = [
    tw_system(8),
    tw_user(8),
    tw_assistant(8),
    tw_user(8),
    tw_assistant(8),
  ]
  // total = 10 tokens
  guard trim_fallback(messages, 10) is Err(TrimError::AlreadyWithinBudget) else {
    fail("expected AlreadyWithinBudget at exact budget")
  }
  guard trim_fallback(messages, 99) is Err(TrimError::AlreadyWithinBudget) else {
    fail("expected AlreadyWithinBudget with slack")
  }
}

///|
test "trim/no progress when nothing droppable" {
  // No user round at all.
  guard trim_fallback([tw_system(8), tw_assistant(8), tw_tool(8)], 3)
    is Err(TrimError::NoProgress) else {
    fail("expected NoProgress without user rounds")
  }
  // System-only transcript.
  guard trim_fallback([tw_system(8)], 1) is Err(TrimError::NoProgress) else {
    fail("expected NoProgress for system-only transcript")
  }
  // Droppable rounds exist but carry zero tokens: no strict shrink possible.
  guard trim_fallback([tw_system(1), tw_user(0), tw_assistant(0)], 0)
    is Err(TrimError::NoProgress) else {
    fail("expected NoProgress for zero-token rounds")
  }
}

///|
test "trim/strictly smaller within budget with minimal drop" {
  let messages = [
    tw_system(8),
    tw_user(8),
    tw_assistant(8),
    tw_user(8),
    tw_assistant(8),
  ]
  // total = 10; dropping round 1 (U+A = 4 tokens) leaves 6 <= target 6.
  let result = trim_fallback(messages, 6)
  guard result is Ok(compact) else { fail("expected Ok") }
  guard compact.mode is Replace else { fail("expected Replace mode") }
  let kept = compact.compacted_messages
  inspect(tw_tags(kept), content="SUA")
  inspect(estimate_tokens(kept), content="6")
  guard estimate_tokens(kept) < estimate_tokens(messages) else {
    fail("trim must strictly shrink")
  }
  // Input untouched.
  inspect(tw_tags(messages), content="SUAUA")
  inspect(estimate_tokens(messages), content="10")
}

///|
test "trim/cut lands exactly before a user message" {
  let messages = [
    tw_system(8),
    tw_user(8),
    tw_assistant(8),
    tw_user(8),
    tw_assistant(8),
  ]
  let result = trim_fallback(messages, 6)
  guard result is Ok(compact) else { fail("expected Ok") }
  let kept = compact.compacted_messages
  // The cut sits between the system head and the first kept round: the
  // first kept message after the system prefix is a UserMessage, never an
  // Assistant/Tool fragment of a dropped round.
  guard kept.length() == 3 else { fail("expected 3 kept messages") }
  guard kept[0] is SystemMessage(..) else {
    fail("system must stay at the head")
  }
  guard kept[1] is UserMessage(..) else {
    fail("cut must land before a UserMessage")
  }
}

///|
test "trim/assistant tool pair never split" {
  let messages = [
    tw_system(8),
    tw_user(8),
    tw_assistant(8),
    tw_tool(40),
    tw_user(8),
    tw_assistant(8),
  ]
  // total = 20 (S2 + U2 + A2 + T10 + U2 + A2). target 17 does not fit at
  // the first round boundary (kept would be 18). An illegal mid-round cut
  // after the assistant (keeping U1 but dropping T1) would fit with tags
  // "SUAUA" — the legal cut must skip the whole round instead.
  let result = trim_fallback(messages, 17)
  guard result is Ok(compact) else { fail("expected Ok") }
  let kept = compact.compacted_messages
  inspect(tw_tags(kept), content="SUA")
  inspect(estimate_tokens(kept), content="6")
  // Tags "SUA" prove the dropped side took the assistant and its tool
  // output away whole — no orphaned tool output survives.
}

///|
test "trim/assistant tool pair kept intact in result" {
  let messages = [
    tw_system(8),
    tw_user(8),
    tw_assistant(8),
    tw_tool(8),
    tw_user(8),
    tw_assistant(8),
    tw_tool(8),
    tw_user(8),
    tw_assistant(40),
  ]
  // total = 26 (S2 + 3 rounds of 4 + final round 12). target 20 skips the
  // first round entirely and keeps the second round's pair intact.
  let result = trim_fallback(messages, 20)
  guard result is Ok(compact) else { fail("expected Ok") }
  let kept = compact.compacted_messages
  inspect(tw_tags(kept), content="SUATUA")
  inspect(estimate_tokens(kept), content="20")
  guard kept[2] is AssistantMessage(..) && kept[3] is ToolMessage(..) else {
    fail("assistant and its tool output must stay adjacent")
  }
}

///|
test "trim/system message preserved" {
  let sys = tw_system(8)
  let messages = [
    sys,
    tw_user(8),
    tw_assistant(8),
    tw_user(8),
    tw_assistant(8),
    tw_user(8),
    tw_assistant(8),
  ]
  // Drop two rounds; the system head still leads the result.
  let result = trim_fallback(messages, 6)
  guard result is Ok(compact) else { fail("expected Ok") }
  let kept = compact.compacted_messages
  inspect(tw_tags(kept), content="SUA")
  guard kept[0] is SystemMessage(..) else { fail("system must be preserved") }
  // Same system content: 8 chars -> 2 tokens.
  inspect(estimate_tokens([kept[0]]), content="2")
}

///|
test "trim/multi-round drops oldest rounds first" {
  let messages = [
    tw_system(8),
    tw_user(8),
    tw_assistant(8),
    tw_user(8),
    tw_assistant(8),
    tw_user(8),
    tw_assistant(8),
  ]
  // total = 14 (head 2 + three rounds of 4). Rounds leave oldest-first:
  // target 12 fits after dropping round 1 (10 kept); target 8 needs round 2 too.
  let first = trim_fallback(messages, 12)
  guard first is Ok(c12) else { fail("expected Ok for target 12") }
  inspect(tw_tags(c12.compacted_messages), content="SUAUA")
  inspect(estimate_tokens(c12.compacted_messages), content="10")
  let second = trim_fallback(messages, 8)
  guard second is Ok(c8) else { fail("expected Ok for target 8") }
  inspect(tw_tags(c8.compacted_messages), content="SUA")
  inspect(estimate_tokens(c8.compacted_messages), content="6")
}

///|
test "trim/budget unreachable returns maximal strictly smaller trim" {
  let messages = [
    tw_system(20),
    tw_user(8),
    tw_assistant(8),
    tw_tool(8),
    tw_user(8),
    tw_assistant(8),
  ]
  // total = 15 (head 5 + two rounds of 5). Even the maximal cut keeps 9 > 5,
  // but 9 is strictly smaller than 15, so the maximal trim is returned.
  let result = trim_fallback(messages, 5)
  guard result is Ok(compact) else { fail("expected Ok with maximal trim") }
  inspect(tw_tags(compact.compacted_messages), content="SUA")
  inspect(estimate_tokens(compact.compacted_messages), content="9")
}
