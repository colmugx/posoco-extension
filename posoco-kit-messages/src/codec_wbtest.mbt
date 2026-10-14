///|
/// Codec tests: request encoding and non-streaming response parsing against
/// documented wire shapes. Deterministic; no network.

///|
/// Test accessors: this toolchain's Json exposes item()/value() rather than
/// indexing syntax. Missing keys/indices abort the test loudly.
fn jget(v : Json, key~ : String) -> Json {
  guard v.value(key) is Some(out) else {
    abort("test fixture: missing key \"\{key}\"")
  }
  out
}

///|
fn jat(v : Json, index~ : Int) -> Json {
  guard v.item(index) is Some(out) else {
    abort("test fixture: missing index \{index}")
  }
  out
}

///|
fn jlen(v : Json) -> Int {
  v.as_array().unwrap_or([]).length()
}

///|
fn codec_tool(name~ : String) -> @posoco.ToolDef {
  {
    name: @posoco.ToolName::unchecked(name),
    description: "test tool \{name}",
    input_schema: { "type": "object" },
    owner: @posoco.OwnerId::unchecked("test"),
    policy: @posoco.ExecutionPolicy::Sequential,
    provenance: None,
  }
}

///|
test "text-only single-turn request and response" {
  let body = encode_request(
    model="test-model",
    max_tokens=1024,
    messages=message_to_wire(
      @posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")]),
    ),
  )
  assert_eq(
    body,
    {
      "model": "test-model",
      "max_tokens": 1024,
      "messages": [
        { "role": "user", "content": [{ "type": "text", "text": "hi" }] },
      ],
    },
  )
  let result = parse_response(
    provider="test",
    {
      "id": "msg_01",
      "type": "message",
      "role": "assistant",
      "model": "test-model",
      "content": [{ "type": "text", "text": "hello" }],
      "stop_reason": "end_turn",
      "stop_sequence": None,
      "usage": { "input_tokens": 10, "output_tokens": 5 },
    },
  )
  assert_eq(
    result.completion.message.content,
    [@posoco.Content::Text("hello")],
  )
  assert_eq(
    result.completion.message.finish_reason,
    @posoco.FinishReason::Stop,
  )
  assert_eq(result.stop_reason, "end_turn")
  assert_eq(result.response_id, "msg_01")
  assert_eq(result.model, "test-model")
  assert_eq(result.extensions, [])
  let usage = result.usage.unwrap_or({
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: None,
    cache_read_input_tokens: None,
  })
  assert_eq(usage.input_tokens, 10)
  assert_eq(usage.output_tokens, 5)
}

///|
test "multi-turn conversation with top-level system and tools" {
  let system = system_to_wire(content=[@posoco.Content::Text("be terse")])
  let transcript : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("q1")]),
    @posoco.Message::AssistantMessage(
      content=[@posoco.Content::Text("a1")],
      tool_calls=[],
      reasoning=None,
      finish_reason=@posoco.FinishReason::Stop,
    ),
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("q2")]),
  ]
  let wire : Array[Json] = []
  for msg in transcript {
    for encoded in message_to_wire(msg) {
      wire.push(encoded)
    }
  }
  let body = encode_request(
    model="m",
    max_tokens=100,
    system=Some(system),
    messages=wire,
    tools=[tool_to_wire(tool=codec_tool(name="read"))],
  )
  assert_eq(
    body,
    {
      "model": "m",
      "max_tokens": 100,
      "system": [{ "type": "text", "text": "be terse" }],
      "messages": [
        { "role": "user", "content": [{ "type": "text", "text": "q1" }] },
        { "role": "assistant", "content": [{ "type": "text", "text": "a1" }] },
        { "role": "user", "content": [{ "type": "text", "text": "q2" }] },
      ],
      "tools": [
        {
          "name": "read",
          "description": "test tool read",
          "input_schema": { "type": "object" },
        },
      ],
    },
  )
}

///|
test "multiple tool definitions and tool_choice" {
  let tools = [
    tool_to_wire(tool=codec_tool(name="a")),
    tool_to_wire(tool=codec_tool(name="b")),
  ]
  let body = encode_request(
    model="m",
    max_tokens=100,
    messages=message_to_wire(
      @posoco.Message::UserMessage(content=[@posoco.Content::Text("go")]),
    ),
    tools=tools,
    options=MessagesRequestOptions::MessagesRequestOptions(
      tool_choice=Some(MessagesToolChoice::Tool(name="a")),
      stop_sequences=["END", "STOP"],
    ),
  )
  assert_eq(jget(body, key="tool_choice"), { "type": "tool", "name": "a" })
  assert_eq(jget(body, key="stop_sequences"), ["END", "STOP"])
  assert_eq(jlen(jget(body, key="tools")), 2)
}

///|
test "assistant tool_use followed by correlated tool_result with is_error" {
  let assistant = @posoco.Message::AssistantMessage(
    content=[],
    tool_calls=[
      {
        call_id: @posoco.CallId::unchecked("toolu_01"),
        name: @posoco.ToolName::unchecked("weather"),
        arguments: { "city": "Paris" },
      },
    ],
    reasoning=None,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let tool_ok = @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("toolu_01"),
    tool_name=@posoco.ToolName::unchecked("weather"),
    outcome=@posoco.ToolOutcome::Success(content="22C", structured=None),
  )
  let wire_assistant = message_to_wire(assistant)
  let wire_tool = message_to_wire(tool_ok)
  // The tool result rides a user message with the original id; no `tool`
  // role is ever fabricated.
  assert_eq(jget(wire_tool[0], key="role"), "user")
  assert_eq(
    jat(jget(wire_assistant[0], key="content"), index=0),
    {
      "type": "tool_use",
      "id": "toolu_01",
      "name": "weather",
      "input": { "city": "Paris" },
    },
  )
  assert_eq(
    jat(jget(wire_tool[0], key="content"), index=0),
    { "type": "tool_result", "tool_use_id": "toolu_01", "content": "22C" },
  )
  let tool_err = @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("toolu_01"),
    tool_name=@posoco.ToolName::unchecked("weather"),
    outcome=@posoco.ToolOutcome::ToolReportedError(
      content="city not found",
      structured=None,
    ),
  )
  assert_eq(
    jat(
      jget(message_to_wire(tool_err)[0], key="content"),
      index=0,
    ),
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01",
      "content": "city not found",
      "is_error": true,
    },
  )
  let runtime_fail = @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("toolu_01"),
    tool_name=@posoco.ToolName::unchecked("weather"),
    outcome=@posoco.ToolOutcome::RuntimeFailure(
      error_category="io",
      message="timed out",
    ),
  )
  assert_eq(
    jget(
      jat(
        jget(message_to_wire(runtime_fail)[0], key="content"),
        index=0,
      ),
      key="is_error",
    ),
    true,
  )
}

///|
test "multiple tool calls in one assistant message" {
  let assistant = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("checking both")],
    tool_calls=[
      {
        call_id: @posoco.CallId::unchecked("toolu_a"),
        name: @posoco.ToolName::unchecked("f"),
        arguments: {},
      },
      {
        call_id: @posoco.CallId::unchecked("toolu_b"),
        name: @posoco.ToolName::unchecked("g"),
        arguments: { "x": 1 },
      },
    ],
    reasoning=None,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let wire = jget(message_to_wire(assistant)[0], key="content")
  assert_eq(jlen(wire), 3)
  assert_eq(jget(jat(wire, index=0), key="type"), "text")
  assert_eq(jget(jat(wire, index=1), key="id"), "toolu_a")
  assert_eq(jget(jat(wire, index=2), key="id"), "toolu_b")
  assert_eq(jget(jat(wire, index=2), key="input"), { "x": 1 })
}

///|
test "image input, url images, and tool-result attachments" {
  let user = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("what is this"),
    @posoco.Content::Image(media_type="image/png", data="aGVsbG8="),
  ])
  let content = jget(message_to_wire(user)[0], key="content")
  assert_eq(
    jat(content, index=1),
    {
      "type": "image",
      "source": {
        "type": "base64",
        "media_type": "image/png",
        "data": "aGVsbG8=",
      },
    },
  )
  let by_url = @posoco.Message::UserMessage(content=[
    @posoco.Content::Image(
      media_type="image/jpeg",
      data="https://example.invalid/pic.jpg",
    ),
  ])
  assert_eq(
    jget(
      jat(
        jget(message_to_wire(by_url)[0], key="content"),
        index=0,
      ),
      key="source",
    ),
    { "type": "url", "url": "https://example.invalid/pic.jpg" },
  )
  let attachment_turn = @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("toolu_shot"),
    tool_name=@posoco.ToolName::unchecked("screenshot"),
    outcome=@posoco.ToolOutcome::SuccessWithAttachments(
      content="captured",
      structured=None,
      attachments=[
        @posoco.Content::Image(media_type="image/png", data="aGk="),
      ],
    ),
  )
  let blocks = jget(
    jat(
      jget(message_to_wire(attachment_turn)[0], key="content"),
      index=0,
    ),
    key="content",
  )
  assert_eq(jlen(blocks), 2)
  assert_eq(jget(jat(blocks, index=0), key="type"), "text")
  assert_eq(
    jget(jget(jat(blocks, index=1), key="source"), key="type"),
    "base64",
  )
  // Unsupported media types are typed errors, never dropped.
  let bad = @posoco.Message::UserMessage(content=[
    @posoco.Content::Image(media_type="image/xyz", data="data"),
  ])
  let result = Ok(message_to_wire(bad)) catch { error => Err(error) }
  match result {
    Err(@posoco.ModelError::RequestBuild(message)) =>
      assert_true(message.contains("media_type"))
    _ => fail("expected media_type rejection")
  }
}

///|
test "non-streaming mixed thinking, text, and tool blocks in original order" {
  let result = parse_response(
    provider="test",
    {
      "id": "msg_02",
      "type": "message",
      "role": "assistant",
      "model": "m",
      "content": [
        {
          "type": "thinking",
          "thinking": "I should check the weather.",
          "signature": "sig-abc",
        },
        { "type": "text", "text": "Let me check." },
        {
          "type": "tool_use",
          "id": "toolu_9",
          "name": "weather",
          "input": { "city": "Oslo" },
        },
      ],
      "stop_reason": "tool_use",
      "stop_sequence": None,
      "usage": { "input_tokens": 20, "output_tokens": 30 },
    },
  )
  assert_eq(
    result.completion.message.content,
    [@posoco.Content::Text("Let me check.")],
  )
  assert_eq(result.completion.message.tool_calls.length(), 1)
  assert_eq(
    result.completion.message.tool_calls[0].call_id.to_string(),
    "toolu_9",
  )
  let reasoning = result.completion.message.reasoning.unwrap_or({
    content: "",
    raw: None,
  })
  assert_true(reasoning.content.contains("check the weather"))
  // Replay state rides the kit envelope and round-trips into the next
  // request verbatim, with the thinking block first.
  let assistant = @posoco.Message::AssistantMessage(
    content=result.completion.message.content,
    tool_calls=result.completion.message.tool_calls,
    reasoning=result.completion.message.reasoning,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let replayed = jget(
    message_to_wire(assistant)[0],
    key="content",
  )
  assert_eq(jget(jat(replayed, index=0), key="type"), "thinking")
  assert_eq(jget(jat(replayed, index=0), key="signature"), "sig-abc")
  assert_eq(jget(jat(replayed, index=1), key="type"), "text")
  assert_eq(jget(jat(replayed, index=2), key="type"), "tool_use")
}

///|
test "stop reason mapping preserves unknown values" {
  assert_eq(map_stop_reason(reason="end_turn"), @posoco.FinishReason::Stop)
  assert_eq(
    map_stop_reason(reason="stop_sequence"),
    @posoco.FinishReason::Stop,
  )
  assert_eq(
    map_stop_reason(reason="tool_use"),
    @posoco.FinishReason::ToolCalls,
  )
  assert_eq(
    map_stop_reason(reason="max_tokens"),
    @posoco.FinishReason::Length,
  )
  assert_eq(
    map_stop_reason(reason="pause_turn"),
    @posoco.FinishReason::Other("pause_turn"),
  )
  assert_eq(
    map_stop_reason(reason="refusal"),
    @posoco.FinishReason::Other("refusal"),
  )
  // Length-truncated tool_use does NOT become ToolCalls: the reducer must
  // not execute partial calls.
  let result = parse_response(
    provider="test",
    {
      "id": "msg_03",
      "type": "message",
      "role": "assistant",
      "model": "m",
      "content": [
        {
          "type": "tool_use",
          "id": "toolu_trunc",
          "name": "f",
          "input": { "partial": true },
        },
      ],
      "stop_reason": "max_tokens",
      "stop_sequence": None,
      "usage": { "input_tokens": 1, "output_tokens": 1 },
    },
  )
  assert_eq(
    result.completion.message.finish_reason,
    @posoco.FinishReason::Length,
  )
}

///|
test "prompt caching usage converts explicitly" {
  let usage = parse_messages_usage(
    provider="test",
    {
      "input_tokens": 100,
      "output_tokens": 50,
      "cache_creation_input_tokens": 200,
      "cache_read_input_tokens": 1000,
    },
  )
  assert_eq(usage.prompt_total(), 1300)
  let canonical = usage.to_canonical()
  assert_eq(canonical.input_tokens, Some(1300))
  assert_eq(canonical.output_tokens, Some(50))
  assert_eq(canonical.total_tokens, Some(1350))
  // Canonical input is the prompt total; the cache hit rate denominator.
  assert_eq(canonical.cached_input_tokens, Some(1000))
  // Miss portion = wire input + cache creation (never read).
  assert_eq(canonical.uncached_input_tokens, Some(300))
  // Without cache dimensions nothing is invented.
  let plain = parse_messages_usage(
    provider="test",
    { "input_tokens": 7, "output_tokens": 3 },
  ).to_canonical()
  assert_eq(plain.input_tokens, Some(7))
  assert_eq(plain.cached_input_tokens, None)
  assert_eq(plain.uncached_input_tokens, None)
  assert_eq(plain.total_tokens, Some(10))
  // Explicit nulls mean "not reported", same as absent.
  let nulled = parse_messages_usage(
    provider="test",
    {
      "input_tokens": 7,
      "output_tokens": 3,
      "cache_creation_input_tokens": None,
      "cache_read_input_tokens": None,
    },
  ).to_canonical()
  assert_eq(nulled.cached_input_tokens, None)
  // Malformed counters are rejected, never zero-filled.
  let bad = Ok(
    parse_messages_usage(
      provider="test",
      { "input_tokens": -1, "output_tokens": 1 },
    ),
  ) catch {
    error => Err(error)
  }
  match bad {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("out_of_range"))
    _ => fail("expected negative usage rejection")
  }
  let partial = Ok(parse_messages_usage(
    provider="test",
    { "output_tokens": 1 },
  )) catch {
    error => Err(error)
  }
  match partial {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("input_tokens"))
    _ => fail("expected missing input_tokens rejection")
  }
}

///|
test "encode validation failures are typed and local" {
  let checks : Array[() -> Unit raise @posoco.ModelError] = [
    // SystemMessage has no Messages placement.
    fn() {
      ignore(
        message_to_wire(
          @posoco.Message::SystemMessage(content=[@posoco.Content::Text("s")]),
        ),
      )
    },
    // Images cannot ride assistant content.
    fn() {
      ignore(
        message_to_wire(
          @posoco.Message::AssistantMessage(
            content=[@posoco.Content::Image(media_type="image/png", data="x")],
            tool_calls=[],
            reasoning=None,
            finish_reason=@posoco.FinishReason::Stop,
          ),
        ),
      )
    },
    // thinking + forced tool_choice is a protocol conflict.
    fn() {
      ignore(
        encode_request(
          model="m",
          max_tokens=100,
          messages=message_to_wire(
            @posoco.Message::UserMessage(content=[@posoco.Content::Text("q")]),
          ),
          options=MessagesRequestOptions::MessagesRequestOptions(
            tool_choice=Some(MessagesToolChoice::Any),
            thinking=Some(ThinkingConfig::Enabled(budget_tokens=2048)),
          ),
        ),
      )
    },
    // thinking forces temperature 1.0.
    fn() {
      ignore(
        encode_request(
          model="m",
          max_tokens=100,
          messages=message_to_wire(
            @posoco.Message::UserMessage(content=[@posoco.Content::Text("q")]),
          ),
          options=MessagesRequestOptions::MessagesRequestOptions(
            temperature=Some(0.7),
            thinking=Some(ThinkingConfig::Enabled(budget_tokens=2048)),
          ),
        ),
      )
    },
    // thinking budget below the protocol floor.
    fn() {
      ignore(
        encode_request(
          model="m",
          max_tokens=100,
          messages=message_to_wire(
            @posoco.Message::UserMessage(content=[@posoco.Content::Text("q")]),
          ),
          options=MessagesRequestOptions::MessagesRequestOptions(
            thinking=Some(ThinkingConfig::Enabled(budget_tokens=512)),
          ),
        ),
      )
    },
    // More than four stop sequences.
    fn() {
      ignore(
        encode_request(
          model="m",
          max_tokens=100,
          messages=message_to_wire(
            @posoco.Message::UserMessage(content=[@posoco.Content::Text("q")]),
          ),
          options=MessagesRequestOptions::MessagesRequestOptions(
            stop_sequences=["1", "2", "3", "4", "5"],
          ),
        ),
      )
    },
    // cache_control ttl is validated locally.
    fn() {
      ignore(
        attach_cache_control(
          { "type": "text", "text": "x" },
          cache_control={ ttl: Some("9h") },
        ),
      )
    },
  ]
  for check in checks {
    let result = Ok(check()) catch { error => Err(error) }
    let failed = match result {
      Err(@posoco.ModelError::RequestBuild(_)) => true
      _ => false
    }
    assert_true(failed)
  }
  // Positive placements still work: system tail, tool definition.
  let cached_system = system_to_wire(
    content=[@posoco.Content::Text("s")],
    cache_control=Some({ ttl: Some("1h") }),
  )
  assert_eq(
    jget(jat(cached_system, index=0), key="cache_control"),
    { "type": "ephemeral", "ttl": "1h" },
  )
  let cached_tool = tool_to_wire(
    tool=codec_tool(name="t"),
    cache_control=Some({ ttl: None }),
  )
  assert_eq(jget(cached_tool, key="cache_control"), { "type": "ephemeral" })
}

///|
test "opaque top-level response fields pass through, malformed shapes reject" {
  let result = parse_response(
    provider="test",
    {
      "id": "msg_x",
      "type": "message",
      "role": "assistant",
      "model": "m",
      "content": [],
      "stop_reason": "end_turn",
      "stop_sequence": None,
      "usage": { "input_tokens": 1, "output_tokens": 1 },
      "container": { "seed": 1 },
      "context_management": "future",
    },
  )
  assert_eq(result.extensions.length(), 2)
  // Malformed content blocks are typed errors with bounded detail.
  let bad = Ok(
    parse_response(
      provider="test",
      {
        "id": "msg_y",
        "type": "message",
        "role": "assistant",
        "model": "m",
        "content": [{ "type": "tool_use", "id": "", "name": "f", "input": {} }],
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
      assert_true(message.contains("tool.id"))
    _ => fail("expected empty tool id rejection")
  }
}


///|
/// An opaque extra field must never shadow request fields validated by the kit.
test "extra_top_level cannot override model or messages" {
  let result = Ok(encode_request(
    model="test",
    max_tokens=128,
    messages=[Json::object({
      "role": Json::string("user"),
      "content": Json::string("hi"),
    })],
    options=MessagesRequestOptions::MessagesRequestOptions(
      extra_top_level=[("model", Json::string("injected"))],
    ),
  )) catch { error => Err(error) }
  match result {
    Err(@posoco.ModelError::RequestBuild(_)) => ()
    _ => fail("expected reserved field rejection")
  }
}

///|
test "request encoder refuses foreign reasoning state" {
  let msg = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("hello")],
    tool_calls=[],
    reasoning=Some({
      content: "thinking",
      raw: Some(Json::object({ "codec": Json::string("foreign") })),
    }),
    finish_reason=@posoco.FinishReason::Stop,
  )
  let result = Ok(message_to_wire(msg)) catch { error => Err(error) }
  match result {
    Err(@posoco.ModelError::RequestBuild(_)) => ()
    _ => fail("expected foreign replay state rejection")
  }
}
