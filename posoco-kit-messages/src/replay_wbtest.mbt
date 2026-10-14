///|
/// Replay-state tests: envelope capture, signature preservation, redacted
/// thinking, stale-state rejection, and mixed assistant turns.

///|
/// Mixed assistant turn fixture (thinking + visible text + tool calls), as
/// the wire delivers it.
fn mixed_assistant_response() -> Json {
  {
    "id": "msg_mix",
    "type": "message",
    "role": "assistant",
    "model": "m",
    "content": [
      {
        "type": "thinking",
        "thinking": "Need weather for two cities.",
        "signature": "sig-enc-1",
      },
      { "type": "text", "text": "Checking both." },
      {
        "type": "tool_use",
        "id": "toolu_1",
        "name": "weather",
        "input": { "city": "Oslo" },
      },
      {
        "type": "tool_use",
        "id": "toolu_2",
        "name": "weather",
        "input": { "city": "Lima" },
      },
    ],
    "stop_reason": "tool_use",
    "stop_sequence": None,
    "usage": { "input_tokens": 10, "output_tokens": 20 },
  }
}

///|
test "signed thinking captures into the envelope and replays verbatim" {
  let result = parse_response(provider="t", mixed_assistant_response())
  let reasoning = result.completion.message.reasoning.unwrap_or({
    content: "",
    raw: None,
  })
  // Canonical content carries the thinking text; the raw envelope carries
  // signatures and ordering.
  assert_true(reasoning.content.contains("two cities"))
  let assistant = @posoco.Message::AssistantMessage(
    content=result.completion.message.content,
    tool_calls=result.completion.message.tool_calls,
    reasoning=result.completion.message.reasoning,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let blocks = jget(message_to_wire(assistant)[0], key="content")
  assert_eq(jget(jat(blocks, index=0), key="type"), "thinking")
  assert_eq(jget(jat(blocks, index=0), key="thinking"), "Need weather for two cities.")
  assert_eq(jget(jat(blocks, index=0), key="signature"), "sig-enc-1")
  assert_eq(jget(jat(blocks, index=1), key="type"), "text")
  assert_eq(jget(jat(blocks, index=1), key="text"), "Checking both.")
  assert_eq(jget(jat(blocks, index=2), key="id"), "toolu_1")
  assert_eq(jget(jat(blocks, index=3), key="id"), "toolu_2")
}

///|
test "redacted thinking replays as opaque state, never as text" {
  let result = parse_response(
    provider="t",
    {
      "id": "msg_red",
      "type": "message",
      "role": "assistant",
      "model": "m",
      "content": [
        { "type": "redacted_thinking", "data": "ZW5jcnlwdGVk" },
        { "type": "text", "text": "Done." },
      ],
      "stop_reason": "end_turn",
      "stop_sequence": None,
      "usage": { "input_tokens": 1, "output_tokens": 1 },
    },
  )
  // The redacted payload does not surface in canonical content.
  assert_eq(
    result.completion.message.content,
    [@posoco.Content::Text("Done.")],
  )
  let assistant = @posoco.Message::AssistantMessage(
    content=result.completion.message.content,
    tool_calls=result.completion.message.tool_calls,
    reasoning=result.completion.message.reasoning,
    finish_reason=@posoco.FinishReason::Stop,
  )
  let blocks = jget(message_to_wire(assistant)[0], key="content")
  assert_eq(jget(jat(blocks, index=0), key="type"), "redacted_thinking")
  assert_eq(jget(jat(blocks, index=0), key="data"), "ZW5jcnlwdGVk")
  assert_eq(jget(jat(blocks, index=1), key="type"), "text")
}

///|
test "editing the assistant turn invalidates stale replay state" {
  let result = parse_response(provider="t", mixed_assistant_response())
  // Same visible payload: replay succeeds.
  let intact = @posoco.Message::AssistantMessage(
    content=result.completion.message.content,
    tool_calls=result.completion.message.tool_calls,
    reasoning=result.completion.message.reasoning,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  assert_eq(jlen(jget(message_to_wire(intact)[0], key="content")), 4)
  // Edited text: the envelope no longer corresponds to the message.
  let edited = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("Checking both cities now.")],
    tool_calls=result.completion.message.tool_calls,
    reasoning=result.completion.message.reasoning,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let result_edited = Ok(message_to_wire(edited)) catch { error => Err(error) }
  match result_edited {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stale"))
    _ => fail("expected stale fingerprint rejection")
  }
  // Dropped tool call: stale too.
  let dropped_call = @posoco.Message::AssistantMessage(
    content=result.completion.message.content,
    tool_calls=[result.completion.message.tool_calls[0]],
    reasoning=result.completion.message.reasoning,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let result_dropped = Ok(message_to_wire(dropped_call)) catch {
    error => Err(error)
  }
  match result_dropped {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stale"))
    _ => fail("expected stale fingerprint rejection")
  }
}

///|
test "foreign and malformed replay state is rejected explicitly" {
  // Foreign codec state must not be silently discarded.
  let foreign = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("visible")],
    tool_calls=[],
    reasoning=Some({
      content: "chain",
      raw: Some({ "codec": "other.kit", "blocks": [] }),
    }),
    finish_reason=@posoco.FinishReason::Stop,
  )
  let foreign_result = Ok(message_to_wire(foreign)) catch { error => Err(error) }
  match foreign_result {
    Err(@posoco.ModelError::RequestBuild(message)) =>
      assert_true(message.contains("foreign_replay"))
    _ => fail("expected explicit foreign-replay rejection")
  }
  // Our codec tag with malformed body: loud typed error, never silent loss.
  let corrupt = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("visible")],
    tool_calls=[],
    reasoning=Some({
      content: "chain",
      raw: Some({ "codec": "posoco.kit.messages", "version": 1 }),
    }),
    finish_reason=@posoco.FinishReason::Stop,
  )
  let result = Ok(message_to_wire(corrupt)) catch { error => Err(error) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("fingerprint"))
    _ => fail("expected malformed envelope rejection")
  }
  // Unknown version: rejected.
  let future = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("v")],
    tool_calls=[],
    reasoning=Some({
      content: "c",
      raw: Some({
        "codec": "posoco.kit.messages",
        "version": 99,
        "fingerprint": "aa",
        "blocks": [],
      }),
    }),
    finish_reason=@posoco.FinishReason::Stop,
  )
  let result_future = Ok(message_to_wire(future)) catch { error => Err(error) }
  match result_future {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("version"))
    _ => fail("expected version rejection")
  }
}

///|
test "empty thinking block with no signature is a capture-time error" {
  let bad = Ok(
    parse_response(
      provider="t",
      {
        "id": "msg_bad",
        "type": "message",
        "role": "assistant",
        "model": "m",
        "content": [{ "type": "thinking", "thinking": "", "signature": "" }],
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "usage": { "input_tokens": 1, "output_tokens": 1 },
      },
    ),
  ) catch {
    error => Err(error)
  }
  match bad {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("replay.thinking"))
    _ => fail("expected empty thinking rejection")
  }
  // A signed thinking block with empty text is still valuable replay state.
  let signed_only = parse_response(
    provider="t",
    {
      "id": "msg_sig",
      "type": "message",
      "role": "assistant",
      "model": "m",
      "content": [
        { "type": "thinking", "thinking": "", "signature": "sig-only" },
      ],
      "stop_reason": "end_turn",
      "stop_sequence": None,
      "usage": { "input_tokens": 1, "output_tokens": 1 },
    },
  )
  assert_true(signed_only.completion.message.reasoning is Some(_))
}

///|
test "opaque future assistant blocks ride the envelope for continuity" {
  let result = parse_response(
    provider="t",
    {
      "id": "msg_fut",
      "type": "message",
      "role": "assistant",
      "model": "m",
      "content": [
        { "type": "text", "text": "answer" },
        {
          "type": "server_tool_use",
          "id": "srvtool_1",
          "name": "web_search",
          "input": { "q": "x" },
        },
      ],
      "stop_reason": "end_turn",
      "stop_sequence": None,
      "usage": { "input_tokens": 1, "output_tokens": 1 },
    },
  )
  let assistant = @posoco.Message::AssistantMessage(
    content=result.completion.message.content,
    tool_calls=result.completion.message.tool_calls,
    reasoning=result.completion.message.reasoning,
    finish_reason=@posoco.FinishReason::Stop,
  )
  let blocks = jget(message_to_wire(assistant)[0], key="content")
  assert_eq(jget(jat(blocks, index=0), key="type"), "text")
  assert_eq(jget(jat(blocks, index=1), key="type"), "server_tool_use")
  assert_eq(jget(jat(blocks, index=1), key="id"), "srvtool_1")
}


///|
/// Replaying a signed assistant turn must preserve thinking and tool_use at
/// their ORIGINAL positions, rather than moving all thinking blocks first.
test "ordered replay keeps thinking interspersed with visible and tool blocks" {
  let result = parse_response(provider="test", {
    "id": "msg_order",
    "type": "message",
    "role": "assistant",
    "model": "m",
    "content": [
      { "type": "text", "text": "First" },
      { "type": "thinking", "thinking": "A", "signature": "sig-A" },
      { "type": "tool_use", "id": "call-a", "name": "lookup", "input": {} },
      { "type": "text", "text": "Second" },
      { "type": "redacted_thinking", "data": "opaque-secret" },
    ],
    "stop_reason": "tool_use",
    "stop_sequence": None,
    "usage": { "input_tokens": 1, "output_tokens": 2 },
  })
  let assistant = @posoco.Message::AssistantMessage(
    content=result.completion.message.content,
    tool_calls=result.completion.message.tool_calls,
    reasoning=result.completion.message.reasoning,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let blocks = jget(message_to_wire(assistant)[0], key="content")
  assert_eq(jget(jat(blocks, index=0), key="type"), "text")
  assert_eq(jget(jat(blocks, index=1), key="type"), "thinking")
  assert_eq(jget(jat(blocks, index=2), key="type"), "tool_use")
  assert_eq(jget(jat(blocks, index=3), key="type"), "text")
  assert_eq(jget(jat(blocks, index=4), key="type"), "redacted_thinking")
  assert_eq(jget(jat(blocks, index=4), key="data"), "opaque-secret")
}
