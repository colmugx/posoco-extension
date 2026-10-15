///|
test "platform endpoints" {
  debug_inspect(
    zai_platform_endpoint("zai"),
    content="Some((\"https://api.z.ai\", \"/api/anthropic\"))",
  )
  debug_inspect(
    zai_platform_endpoint("bigmodel"),
    content="Some((\"https://open.bigmodel.cn\", \"/api/anthropic\"))",
  )
  debug_inspect(zai_platform_endpoint("bogus"), content="None")
}

///|
test "for_model applies the uniform posture to every model id" {
  for model in ["glm-5.3", "glm-5.3-flash", "glm-something-new"] {
    let config = ZaiConfig::for_model(
      "key",
      model,
      base_url="https://api.z.ai",
      endpoint_prefix="/api/anthropic",
    )
    inspect(config.reasoning_effort, content="high")
    inspect(config.max_output_tokens, content="32768")
    debug_inspect(config.context_window, content="None")
  }
}

///|
test "with_reasoning_effort rejects off and unknown levels" {
  let config = ZaiConfig::for_model(
    "key",
    "glm-5.3",
    base_url="https://api.z.ai",
    endpoint_prefix="/api/anthropic",
  )
  for effort in ["off", "ultra"] {
    try config.with_reasoning_effort(effort) catch {
      @posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~) => {
        inspect(manifest_id, content="posoco_ext_zai")
        inspect(
          detail,
          content="unsupported reasoning effort: \{effort} (thinking stays enabled; use low | high | max)",
        )
      }
      _ => fail("expected ManifestSchemaError")
    } noraise {
      _ => fail("expected failure for \{effort}")
    }
  }
  let lowered = config.with_reasoning_effort("low")
  inspect(lowered.reasoning_effort, content="low")
}

///|
test "headers carry the messages protocol version" {
  let config = ZaiConfig::for_model(
    "key",
    "glm-5.3",
    base_url="https://api.z.ai",
    endpoint_prefix="/api/anthropic",
  )
  let headers = build_headers(config)
  guard headers.get("anthropic-version") is Some(version) else {
    fail("missing anthropic-version")
  }
  inspect(version, content="2023-06-01")
  guard headers.get("Authorization") is Some(authorization) else {
    fail("missing Authorization")
  }
  inspect(authorization, content="Bearer key")
}

///|
fn messages_config(model~ : String = "glm-5.3") -> ZaiConfig {
  ZaiConfig::for_model(
    "key",
    model,
    base_url="https://api.z.ai",
    endpoint_prefix="/api/anthropic",
  )
}

///|
fn default_chat_options() -> @posoco.ChatOptions {
  { temperature: None, max_output_tokens: None, }
}

///|
fn wire_int_field(body : Json, key~ : String) -> Int32 {
  let value = if body is Object(obj) { obj.get(key) } else { None }
  guard value is Some(Json::Number(n, ..)) else {
    abort("test fixture: missing number field \"\{key}\"")
  }
  n.to_int()
}

///|
test "encode: uniform thinking posture and effort on the wire" {
  let body = build_messages_request(
    messages_config(),
    [@posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")])],
    [],
    default_chat_options(),
  )
  json_inspect(body, content={
    "model": "glm-5.3",
    "max_tokens": 32768,
    "messages": [
      { "role": "user", "content": [{ "type": "text", "text": "hi" }] },
    ],
    "thinking": { "type": "enabled" },
    "reasoning_effort": "high",
  })
}

///|
test "encode: streaming requests enable SSE while non-streaming requests do not" {
  let messages = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")]),
  ]
  let streaming = build_messages_request(
    messages_config(),
    messages,
    [],
    default_chat_options(),
    stream=true,
  )
  assert_true(streaming is { "stream": true, .. })
  let non_streaming = build_messages_request(
    messages_config(),
    messages,
    [],
    default_chat_options(),
    stream=false,
  )
  assert_true(non_streaming is { "stream"? : None, .. })
}

///|
test "encode: host max_output_tokens overrides the config default" {
  let config = ZaiConfig::for_model(
    "key",
    "glm-5.3",
    base_url="https://api.z.ai",
    endpoint_prefix="/api/anthropic",
    max_output_tokens=777,
  )
  let body = build_messages_request(
    config,
    [@posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")])],
    [],
    { temperature: None, max_output_tokens: Some(1024), },
  )
  inspect(wire_int_field(body, key="max_tokens"), content="1024")
  let fallback = build_messages_request(
    config,
    [@posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")])],
    [],
    default_chat_options(),
  )
  inspect(wire_int_field(fallback, key="max_tokens"), content="777")
}

///|
test "encode: temperature above 1.0 is a typed range error" {
  try
    build_messages_request(
      messages_config(),
      [@posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")])],
      [],
      { temperature: Some(1.2), max_output_tokens: None, },
    )
  catch {
    @posoco.ModelError::RequestBuild(message) =>
      inspect(message.contains("category=range"), content="true")
    _ => fail("expected RequestBuild")
  } noraise {
    _ => fail("expected failure")
  }
}

///|
test "encode: system content lifts to the top-level system field" {
  let body = build_messages_request(
    messages_config(),
    [
      @posoco.Message::SystemMessage(content=[@posoco.Content::Text("be brief")]),
      @posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")]),
      @posoco.Message::SystemMessage(content=[
        @posoco.Content::Text("also honest"),
      ]),
    ],
    [],
    default_chat_options(),
  )
  json_inspect(body, content={
    "model": "glm-5.3",
    "max_tokens": 32768,
    "system": [
      { "type": "text", "text": "be brief" },
      { "type": "text", "text": "also honest" },
    ],
    "messages": [
      { "role": "user", "content": [{ "type": "text", "text": "hi" }] },
    ],
    "thinking": { "type": "enabled" },
    "reasoning_effort": "high",
  })
}

///|
fn grep_call() -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("c1"),
    name: @posoco.ToolName::unchecked("grep"),
    arguments: Json::object({}),
  }
}

///|
test "encode: tool calls and tool results take the messages shapes" {
  let body = build_messages_request(
    messages_config(),
    [
      @posoco.Message::UserMessage(content=[@posoco.Content::Text("run")]),
      @posoco.Message::AssistantMessage(
        content=[],
        tool_calls=[grep_call()],
        reasoning=None,
        finish_reason=@posoco.FinishReason::ToolCalls,
      ),
      @posoco.Message::ToolMessage(
        call_id=@posoco.CallId::unchecked("c1"),
        tool_name=@posoco.ToolName::unchecked("grep"),
        outcome=@posoco.ToolOutcome::Success(content="found", structured=None),
      ),
    ],
    [],
    default_chat_options(),
  )
  json_inspect(body, content={
    "model": "glm-5.3",
    "max_tokens": 32768,
    "messages": [
      { "role": "user", "content": [{ "type": "text", "text": "run" }] },
      {
        "role": "assistant",
        "content": [
          { "type": "tool_use", "id": "c1", "name": "grep", "input": {} },
        ],
      },
      {
        "role": "user",
        "content": [
          { "type": "tool_result", "tool_use_id": "c1", "content": "found" },
        ],
      },
    ],
    "thinking": { "type": "enabled" },
    "reasoning_effort": "high",
  })
}

///|
test "decode + replay: thinking blocks survive the round trip" {
  let json : Json = @json.parse(
    (
      #|{
      #|  "type": "message",
      #|  "role": "assistant",
      #|  "id": "msg_1",
      #|  "model": "glm-5.3",
      #|  "content": [
      #|    { "type": "thinking", "thinking": "hmm", "signature": "sig" },
      #|    { "type": "tool_use", "id": "call_1", "name": "read", "input": {"path": "a"} }
      #|  ],
      #|  "stop_reason": "tool_use",
      #|  "usage": { "input_tokens": 10, "output_tokens": 5 }
      #|}
    ),
  ) catch {
    _ => fail("fixture json")
  }
  let result = @messages.parse_response(provider="zai", json)
  let completion = result.completion
  inspect(completion.has_tool_calls(), content="true")
  let replayed = @messages.message_to_wire(
    @posoco.Message::AssistantMessage(
      content=completion.message.content,
      tool_calls=completion.message.tool_calls,
      reasoning=completion.message.reasoning,
      finish_reason=completion.message.finish_reason,
    ),
  )
  json_inspect(replayed, content=[
    {
      "role": "assistant",
      "content": [
        { "type": "thinking", "thinking": "hmm", "signature": "sig" },
        {
          "type": "tool_use",
          "id": "call_1",
          "name": "read",
          "input": { "path": "a" },
        },
      ],
    },
  ])
}

///|
test "classify: quota 429 keeps typed reset, others redact" {
  let body = "{\"error\":{\"code\":\"1308\",\"message\":\"Usage limit reached for 5 hour(s). Your limit will reset at 2026-08-21 15:04:16\"}}"
  let err = classify_zai_http_error("chat.http_status", 429, body, now_ms=0L)
  guard err is Some(@posoco.ModelError::RateLimited(info)) else {
    fail("expected RateLimited")
  }
  debug_inspect(
    info.provider_code,
    content=(
      #|Some("1308")
    ),
  )
  // No explicit tz in the message -> z.ai default UTC+8.
  debug_inspect(info.reset_at_ms, content="Some(1787295856000)")
  let transient = classify_zai_http_error(
    "chat.http_status",
    429,
    "{\"error\":{\"code\":1302,\"message\":\"Rate limit reached for requests\"}}",
    now_ms=0L,
  )
  guard transient is Some(@posoco.ModelError::RateLimited(transient_info)) else {
    fail("expected RateLimited")
  }
  debug_inspect(transient_info.reset_at_ms, content="None")
  let server_error = classify_zai_http_error(
    "chat.http_status",
    500,
    "internal",
    now_ms=0L,
  )
  guard server_error is Some(@posoco.ModelError::Transport(_)) else {
    fail("expected Transport")
  }
  debug_inspect(
    classify_zai_http_error("chat.http_status", 200, "", now_ms=0L),
    content="None",
  )
}

///|
test "encode: vision model sends native image blocks" {
  let body = build_messages_request(
    messages_config(model="glm-5.3-flash"),
    [
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Text("what is this?"),
        @posoco.Content::Image(media_type="image/png", data="aGVsbG8="),
      ]),
    ],
    [],
    default_chat_options(),
  )
  json_inspect(body, content={
    "model": "glm-5.3-flash",
    "max_tokens": 32768,
    "messages": [
      {
        "role": "user",
        "content": [
          { "type": "text", "text": "what is this?" },
          {
            "type": "image",
            "source": {
              "type": "base64",
              "media_type": "image/png",
              "data": "aGVsbG8=",
            },
          },
        ],
      },
    ],
    "thinking": { "type": "enabled" },
    "reasoning_effort": "high",
  })
}

///|
test "encode: non-vision model downgrades images and tool attachments" {
  let body = build_messages_request(
    messages_config(),
    [
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Text("see this?"),
        @posoco.Content::Image(media_type="image/png", data="aGVsbG8="),
      ]),
    ],
    [],
    default_chat_options(),
  )
  json_inspect(body, content={
    "model": "glm-5.3",
    "max_tokens": 32768,
    "messages": [
      {
        "role": "user",
        "content": [
          { "type": "text", "text": "see this?" },
          {
            "type": "text",
            "text": "[Attached image/png, ~0 KB, omitted: this model does not accept image input]",
          },
        ],
      },
    ],
    "thinking": { "type": "enabled" },
    "reasoning_effort": "high",
  })
  let with_attachment = build_messages_request(
    messages_config(),
    [
      @posoco.Message::UserMessage(content=[@posoco.Content::Text("run")]),
      @posoco.Message::AssistantMessage(
        content=[],
        tool_calls=[grep_call()],
        reasoning=None,
        finish_reason=@posoco.FinishReason::ToolCalls,
      ),
      @posoco.Message::ToolMessage(
        call_id=@posoco.CallId::unchecked("c1"),
        tool_name=@posoco.ToolName::unchecked("grep"),
        outcome=@posoco.ToolOutcome::SuccessWithAttachments(
          content="found",
          structured=None,
          attachments=[
            @posoco.Content::Image(media_type="image/jpeg", data="aGk="),
          ],
        ),
      ),
    ],
    [],
    default_chat_options(),
  )
  let messages = if with_attachment is Object(obj) {
    obj.get("messages")
  } else {
    None
  }
  match messages {
    Some(Json::Array(messages)) =>
      match messages[2] {
        Json::Object(turn) =>
          match turn.get("content") {
            Some(Json::Array(blocks)) =>
              match blocks[0] {
                Json::Object(result_block) =>
                  match result_block.get("content") {
                    Some(Json::String(text)) =>
                      inspect(
                        text,
                        content=(
                          #|found
                          #|[Attached image/jpeg, ~0 KB, omitted: this model does not accept image input]
                        ),
                      )
                    _ => fail("tool_result content must be a string")
                  }
                _ => fail("tool_result must be an object")
              }
            _ => fail("tool turn content must be an array")
          }
        _ => fail("tool turn must be an object")
      }
    _ => fail("messages must be an array")
  }
}

///|
test "supports_images: only documented vision models, never guessed" {
  assert_true(zai_supports_images("glm-5.3-flash"))
  assert_false(zai_supports_images("glm-5.3"))
  // Undocumented/unknown ids stay conservative even when the name looks
  // vision-capable — image input is declared, not inferred.
  assert_false(zai_supports_images("glm-4.5v"))
  assert_false(zai_supports_images("glm-5.9-vision"))
  assert_false(zai_supports_images("some-other"))
}
