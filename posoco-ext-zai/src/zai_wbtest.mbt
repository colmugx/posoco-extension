///|
test "platform endpoints" {
  debug_inspect(
    zai_platform_endpoint("zai"),
    content="Some((\"https://api.z.ai\", \"/api/paas/v4\"))",
  )
  debug_inspect(
    zai_platform_endpoint("bigmodel"),
    content="Some((\"https://open.bigmodel.cn\", \"/api/paas/v4\"))",
  )
  debug_inspect(zai_platform_endpoint("bogus"), content="None")
}

///|
test "for_model picks per-model thinking defaults" {
  let glm5 = ZaiConfig::for_model(
    "key",
    "glm-5.3",
    base_url="https://api.z.ai",
    endpoint_prefix="/api/paas/v4",
  )
  inspect(glm5.reasoning_effort, content="high")
  let glm4 = ZaiConfig::for_model(
    "key",
    "glm-4.5-air",
    base_url="https://api.z.ai",
    endpoint_prefix="/api/paas/v4",
  )
  inspect(glm4.reasoning_effort, content="")
  inspect(glm4.thinking_efforts.length(), content="0")
  let port5 = ZaiModelPort(glm5)
  let port4 = ZaiModelPort(glm4)
  debug_inspect(port5.thinking_state(), content="(true, Some(\"high\"))")
  debug_inspect(port4.thinking_state(), content="(true, None)")
  let off = glm5.with_reasoning_effort("off")
  debug_inspect(ZaiModelPort(off).thinking_state(), content="(false, None)")
}

///|
test "with_reasoning_effort rejects unknown levels" {
  let config = ZaiConfig::for_model(
    "key",
    "glm-5.3",
    base_url="https://api.z.ai",
    endpoint_prefix="/api/paas/v4",
  )
  try config.with_reasoning_effort("ultra") catch {
    @posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~) => {
      inspect(manifest_id, content="posoco_ext_zai")
      inspect(detail, content="unsupported reasoning effort: ultra")
    }
    _ => fail("expected ManifestSchemaError")
  } noraise {
    _ => fail("expected failure")
  }
}

///|
test "encode: thinking and reasoning_effort on the wire" {
  let config = ZaiConfig::for_model(
    "key",
    "glm-5.3",
    base_url="https://api.z.ai",
    endpoint_prefix="/api/paas/v4",
  )
  let body = build_chat_request(
    [@posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")])],
    [],
    { temperature: None, max_output_tokens: None, },
    config.model,
    false,
    true,
    Some("high"),
  )
  json_inspect(body, content={
    "model": "glm-5.3",
    "messages": [{ "role": "user", "content": "hi" }],
    "thinking": { "type": "enabled" },
    "reasoning_effort": "high",
  })
}

///|
/// Encode a minimal request and expose its top-level fields.
fn encode_request(model : String, stream : Bool) -> Map[String, Json] {
  let body = build_chat_request(
    [@posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")])],
    [],
    { temperature: None, max_output_tokens: None, },
    model,
    stream,
    true,
    None,
  )
  guard body is Object(fields) else { abort("expected JSON object") }
  fields
}

///|
test "encode: tool_stream rides along when streaming glm-4.6+" {
  json_inspect(encode_request("glm-5.3", true), content={
    "model": "glm-5.3",
    "messages": [{ "role": "user", "content": "hi" }],
    "thinking": { "type": "enabled" },
    "stream": true,
    "stream_options": { "include_usage": true },
    "tool_stream": true,
  })
  for model in ["glm-5", "glm-5.1", "glm-4.6", "glm-4.7", "glm-5.3-air"] {
    let fields = encode_request(model, true)
    guard fields.contains("tool_stream") else {
      fail("expected tool_stream for \{model}")
    }
    assert_true(fields["tool_stream"] is True)
  }
}

///|
test "encode: tool_stream omitted for unsupported models and non-streaming" {
  for model in ["glm-4.5", "glm-4.5-air", "some-other"] {
    inspect(
      encode_request(model, true).contains("tool_stream"),
      content="false",
    )
  }
  inspect(
    encode_request("glm-4.6", false).contains("tool_stream"),
    content="false",
  )
  assert_false(supports_tool_stream("glm"))
  assert_false(supports_tool_stream("glm-4"))
  assert_true(supports_tool_stream("prefix-glm-4.6v"))
  assert_false(supports_tool_stream("glm-4."))
}

///|
test "encode: reasoning_content only resent with tool_calls" {
  let reasoning : @posoco.Reasoning? = Some({ content: "thought", raw: None, })
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("c1"),
    name: @posoco.ToolName::unchecked("grep"),
    arguments: Json::object({}),
  }
  let with_tools = encode_message(
    @posoco.Message::AssistantMessage(
      content=[],
      tool_calls=[call],
      reasoning~,
      finish_reason=@posoco.FinishReason::ToolCalls,
    ),
  )
  json_inspect(with_tools, content={
    "role": "assistant",
    "content": "",
    "tool_calls": [
      {
        "id": "c1",
        "type": "function",
        "function": { "name": "grep", "arguments": "{}" },
      },
    ],
    "reasoning_content": "thought",
  })
  let without_tools = encode_message(
    @posoco.Message::AssistantMessage(
      content=[@posoco.Content::Text("answer")],
      tool_calls=[],
      reasoning~,
      finish_reason=@posoco.FinishReason::Stop,
    ),
  )
  json_inspect(without_tools, content={
    "role": "assistant",
    "content": "answer",
  })
}

///|
test "decode: reasoning, tool calls and cached usage" {
  let json : Json = @json.parse(
    (
      #|{
      #|  "choices": [{
      #|    "message": {
      #|      "content": "done",
      #|      "reasoning_content": "thinking hard",
      #|      "tool_calls": [{
      #|        "id": "call_1",
      #|        "type": "function",
      #|        "function": { "name": "read", "arguments": "{\"path\":\"a\"}" }
      #|      }]
      #|    },
      #|    "finish_reason": "tool_calls"
      #|  }],
      #|  "usage": {
      #|    "prompt_tokens": 100,
      #|    "completion_tokens": 20,
      #|    "total_tokens": 120,
      #|    "prompt_tokens_details": { "cached_tokens": 60 }
      #|  }
      #|}
    ),
  ) catch {
    _ => fail("fixture json")
  }
  let completion = decode_chat_response(json)
  inspect(completion.has_tool_calls(), content="true")
  inspect(completion.tool_calls()[0].name.to_string(), content="read")
  match completion.message.reasoning {
    Some(r) => inspect(r.content, content="thinking hard")
    None => fail("expected reasoning")
  }
  inspect(
    completion.finish_reason() is @posoco.FinishReason::ToolCalls,
    content="true",
  )
  debug_inspect(
    completion.usage,
    content=(
      #|Some(
      #|  {
      #|    input_tokens: Some(100),
      #|    output_tokens: Some(20),
      #|    total_tokens: Some(120),
      #|    cached_input_tokens: Some(60),
      #|    uncached_input_tokens: None,
      #|  },
      #|)
    ),
  )
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
