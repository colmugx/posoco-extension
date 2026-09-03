///|
fn tk_user(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
fn tk_system(text : String) -> @posoco.Message {
  @posoco.Message::SystemMessage(content=[@posoco.Content::Text(text)])
}

///|
/// Assistant message with text, one tool call on `{}` arguments, and
/// optional reasoning text.
fn tk_assistant_call(
  name : String,
  text : String,
  reasoning? : String,
) -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text(text)],
    tool_calls=[
      @posoco.ToolCall::{
        call_id: @posoco.CallId::unchecked("call_" + name),
        name: @posoco.ToolName::unchecked(name),
        arguments: Json::object({}),
      },
    ],
    reasoning=match reasoning {
      Some(r) => Some(@posoco.Reasoning::{ content: r, raw: None, })
      None => None
    },
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
}

///|
/// Assistant message with tool calls but no content: an evictable shell.
fn tk_assistant_shell(name : String) -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=[],
    tool_calls=[
      @posoco.ToolCall::{
        call_id: @posoco.CallId::unchecked("call_" + name),
        name: @posoco.ToolName::unchecked(name),
        arguments: Json::object({}),
      },
    ],
    reasoning=None,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
}

///|
fn tk_tool(name : String, content : String) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_" + name),
    tool_name=@posoco.ToolName::unchecked(name),
    outcome=@posoco.ToolOutcome::Success(content~, structured=None),
  )
}

///|
/// "abcd" repeated n times: exactly 4n chars = exactly n estimated tokens.
fn tk_big_tokens(n : Int) -> String {
  let sb = StringBuilder()
  for _ in 0..<n {
    sb.write_string("abcd")
  }
  sb.to_string()
}

///|
/// [system, u1, a1(call), t1, u2, a2(call), t2, u3, a3(call), t3, u4]:
/// four user turns, three of them carrying one tool pair each.
fn tk_four_turn_transcript() -> Array[@posoco.Message] {
  [
    tk_system("sys"),
    tk_user("turn one"),
    tk_assistant_call("alpha", "found one", reasoning="abcd"),
    tk_tool("alpha", tk_big_tokens(100)),
    tk_user("turn two"),
    tk_assistant_call("beta", "found two"),
    tk_tool("beta", tk_big_tokens(100)),
    tk_user("turn three"),
    tk_assistant_call("gamma", "found three"),
    tk_tool("gamma", tk_big_tokens(100)),
    tk_user("turn four"),
  ]
}

///|
test "estimate_tokens rounds characters over four up" {
  inspect(estimate_tokens(""), content="0")
  inspect(estimate_tokens("ab"), content="1")
  inspect(estimate_tokens("abcd"), content="1")
  inspect(estimate_tokens("abcde"), content="2")
}

///|
test "fewer than three user turns evicts nothing" {
  let messages = [
    tk_system("sys"),
    tk_user("turn one"),
    tk_assistant_call("alpha", "found one"),
    tk_tool("alpha", tk_big_tokens(100)),
    tk_user("turn two"),
  ]
  let result = evict_old_tool_results(messages)
  inspect(result.evicted_tool_calls, content="0")
  inspect(result.evicted_tokens, content="0")
  inspect(result.messages.length(), content="5")
  assert_true(result.messages[2] == messages[2])
  assert_true(result.messages[3] == messages[3])
}

///|
test "exactly three user turns is fully protected" {
  let messages = [
    tk_user("turn one"),
    tk_assistant_call("alpha", "found one"),
    tk_tool("alpha", tk_big_tokens(100)),
    tk_user("turn two"),
    tk_assistant_call("beta", "found two"),
    tk_tool("beta", tk_big_tokens(100)),
    tk_user("turn three"),
  ]
  let result = evict_old_tool_results(messages)
  inspect(result.evicted_tool_calls, content="0")
  inspect(result.messages.length(), content="7")
  for i, message in messages {
    assert_true(result.messages[i] == message)
  }
}

///|
test "four user turns evicts only the first turn's tool pair" {
  let messages = tk_four_turn_transcript()
  let result = evict_old_tool_results(messages)
  inspect(result.evicted_tool_calls, content="1")
  // freed = payload (100) + call "search"-shaped name/args (2) + reasoning (1)
  inspect(result.evicted_tokens, content="103")
  inspect(result.messages.length(), content="10")
  // skeleton and protected turns survive verbatim
  assert_true(result.messages[0] == messages[0])
  assert_true(result.messages[1] == messages[1])
  for i in 3..<10 {
    assert_true(result.messages[i] == messages[i + 1])
  }
  // the old assistant keeps its text, loses calls and reasoning
  guard result.messages[2]
    is AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) else {
    fail("expected a rewritten assistant")
  }
  inspect(content.length(), content="1")
  inspect(tool_calls.length(), content="0")
  assert_true(reasoning is None)
  assert_true(finish_reason is @posoco.FinishReason::ToolCalls)
  // the input transcript was not mutated: the old assistant still carries
  // its tool call and the tool message is still in place
  inspect(messages.length(), content="11")
  guard messages[2] is AssistantMessage(tool_calls~, ..) else {
    fail("expected the original assistant to keep its tool calls")
  }
  inspect(tool_calls.length(), content="1")
  guard messages[3] is ToolMessage(..) else {
    fail("expected the original tool message to remain in the input")
  }
}

///|
test "assistant without text collapses entirely" {
  let messages = [
    tk_user("turn one"),
    tk_assistant_shell("alpha"),
    tk_tool("alpha", tk_big_tokens(50)),
    tk_user("turn two"),
    tk_user("turn three"),
    tk_user("turn four"),
  ]
  let result = evict_old_tool_results(messages)
  inspect(result.evicted_tool_calls, content="1")
  inspect(result.evicted_tokens, content="52")
  inspect(result.messages.length(), content="4")
  assert_true(result.messages[0] == messages[0])
  for i in 1..<4 {
    assert_true(result.messages[i] == messages[i + 2])
  }
}

///|
test "orphan tool message before the boundary is kept" {
  let messages = [
    tk_user("turn one"),
    tk_tool("orphan", tk_big_tokens(100)),
    tk_user("turn two"),
    tk_user("turn three"),
    tk_user("turn four"),
  ]
  let result = evict_old_tool_results(messages)
  inspect(result.evicted_tool_calls, content="0")
  inspect(result.evicted_tokens, content="0")
  inspect(result.messages.length(), content="5")
  assert_true(result.messages[1] == messages[1])
}

///|
test "protect_user_turns widens or narrows the window" {
  let messages = tk_four_turn_transcript()
  let narrow = evict_old_tool_results(messages, protect_user_turns=1)
  inspect(narrow.evicted_tool_calls, content="3")
  inspect(narrow.messages.length(), content="8")
  let wide = evict_old_tool_results(messages, protect_user_turns=4)
  inspect(wide.evicted_tool_calls, content="0")
  inspect(wide.messages.length(), content="11")
  // degenerate values clamp to one protected turn
  let clamped = evict_old_tool_results(messages, protect_user_turns=0)
  inspect(clamped.evicted_tool_calls, content="3")
}

///|
test "estimate_transcript_tokens sums messages including reasoning" {
  let messages = tk_four_turn_transcript()
  // system "sys" 1 + users (2+2+3+3) + assistant texts (3+3+3)
  // + calls (2+2+2) + reasoning 1 + payloads (100×3)
  inspect(estimate_transcript_tokens(messages), content="327")
  let evicted = evict_old_tool_results(messages)
  inspect(estimate_transcript_tokens(evicted.messages), content="224")
}
