///|
/// Blackbox tests for posoco-ext-deepseek wire encoding/decoding.
/// These test the pure encode/decode logic without any network calls.

///|
fn user_msg(text : String) -> @posoco.Message {
  {
    role: User,
    content: [@posoco.Content::Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: None,
    reasoning_content: None,
  }
}

///|
fn assistant_msg(text : String) -> @posoco.Message {
  {
    role: @posoco.Role::Assistant,
    content: [@posoco.Content::Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: None,
    reasoning_content: None,
  }
}

///|
fn chat_options(effort : @posoco.ReasoningEffort?) -> @posoco.ChatOptions {
  {
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: effort,
  }
}

///|
fn assert_json_field_string(
  obj : Map[String, Json],
  key : String,
  expected : String,
) -> Unit raise {
  match obj.get(key) {
    Some(String(s)) => assert_eq(s, expected)
    _ => fail("expected string field: " + key)
  }
}

///|
test "encode_message_basic" {
  let msg = user_msg("hello")
  let json = encode_message(msg)
  // Should have role=user, content="hello", no reasoning_content
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("role") {
    Some(String(r)) => assert_eq(r, "user")
    _ => fail("expected role string")
  }
  match obj.get("content") {
    Some(String(c)) => assert_eq(c, "hello")
    _ => fail("expected content string")
  }
  // reasoning_content must NOT be present (DeepSeek optimization)
  match obj.get("reasoning_content") {
    None => ()
    _ => fail("reasoning_content should not be encoded")
  }
}

///|
test "encode_message_assistant_no_reasoning" {
  // Even an assistant message from a reasoning model must not carry
  // reasoning_content when re-serialized (prefix cache protection).
  let msg = assistant_msg("answer")
  let json = encode_message(msg)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("role") {
    Some(String(r)) => assert_eq(r, "assistant")
    _ => fail("expected assistant role")
  }
  match obj.get("reasoning_content") {
    None => ()
    _ => fail("assistant history must not carry reasoning_content")
  }
}

///|
test "encode_message_with_tool_calls" {
  let msg : @posoco.Message = {
    role: @posoco.Role::Assistant,
    content: [],
    tool_calls: [
      {
        id: "call_1",
        name: "read_file",
        arguments: Json::object({ "path": Json::string("/tmp/x") }),
      },
    ],
    tool_call_id: None,
    name: None,
    reasoning_content: None,
  }
  let json = encode_message(msg)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("tool_calls") {
    Some(Array(tcs)) => {
      assert_eq(tcs.length(), 1)
      guard tcs[0] is Object(tc0) else { fail("expected tool_call object") }
      match tc0.get("id") {
        Some(String(id)) => assert_eq(id, "call_1")
        _ => fail("expected call id")
      }
      match tc0.get("function") {
        Some(Object(f)) =>
          match f.get("name") {
            Some(String(n)) => assert_eq(n, "read_file")
            _ => fail("expected function name")
          }
        _ => fail("expected function object")
      }
    }
    _ => fail("expected tool_calls array")
  }
}

///|
test "decode_chat_response_basic" {
  // Minimal valid DeepSeek response
  let resp_json : Json = {
    "choices": [
      {
        "message": { "role": "assistant", "content": "hello world" },
        "finish_reason": "stop",
      },
    ],
    "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 },
  }
  let resp = decode_chat_response(resp_json)
  // Verify content
  assert_eq(resp.message.content.length(), 1)
  match resp.message.content[0] {
    Text(t) => assert_eq(t, "hello world")
    _ => fail("expected Text content")
  }
  // Verify finish reason
  assert_true(resp.finish_reason is @posoco.FinishReason::Stop)
  // Verify usage
  match resp.usage {
    Some(u) =>
      match u.total_tokens {
        Some(n) => assert_eq(n, 15)
        None => fail("expected total_tokens")
      }
    None => fail("expected usage")
  }
  // Verify no reasoning (basic chat has none)
  match resp.reasoning_content {
    None => ()
    _ => fail("basic chat should have no reasoning")
  }
}

///|
test "decode_chat_response_with_reasoning" {
  // deepseek-reasoner response includes reasoning_content
  let resp_json : Json = {
    "choices": [
      {
        "message": {
          "role": "assistant",
          "content": "42",
          "reasoning_content": "let me think...",
        },
        "finish_reason": "stop",
      },
    ],
  }
  let resp = decode_chat_response(resp_json)
  match resp.reasoning_content {
    Some(r) => assert_eq(r, "let me think...")
    None => fail("expected reasoning_content")
  }
  match resp.message.content[0] {
    Text(t) => assert_eq(t, "42")
    _ => fail("expected Text content")
  }
}

///|
test "decode_chat_response_with_tool_calls" {
  let resp_json : Json = {
    "choices": [
      {
        "message": {
          "role": "assistant",
          "content": "",
          "tool_calls": [
            {
              "id": "call_1",
              "type": "function",
              "function": {
                "name": "read_file",
                "arguments": "{\"path\":\"/tmp/x\"}",
              },
            },
          ],
        },
        "finish_reason": "tool_calls",
      },
    ],
  }
  let resp = decode_chat_response(resp_json)
  assert_eq(resp.tool_calls.length(), 1)
  let tc = resp.tool_calls[0]
  assert_eq(tc.id, "call_1")
  assert_eq(tc.name, "read_file")
  // arguments should be parsed JSON
  guard tc.arguments is Object(args) else { fail("expected arguments object") }
  match args.get("path") {
    Some(String(p)) => assert_eq(p, "/tmp/x")
    _ => fail("expected path argument")
  }
  assert_true(resp.finish_reason is @posoco.FinishReason::ToolCalls)
}

///|
test "decode_chat_response_api_error" {
  let resp_json : Json = {
    "error": { "message": "Invalid API key", "type": "authentication_error" },
  }
  // Should raise ModelError::Transport
  match (Ok(decode_chat_response(resp_json)) catch { e => Err(e) }) {
    Err(@posoco.ModelError::Transport(msg)) =>
      assert_true(msg.contains("Invalid API key"))
    Err(_) => fail("expected Transport error")
    Ok(_) => fail("expected error")
  }
}

///|
/// SSE parser tests — process_deepseek_sse is pure (no network).

///|
test "sse_text_delta" {
  let acc = @posoco.StreamAccumulator::new()
  let chunks : Array[@posoco.StreamChunk] = []
  let data = "{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}"
  let done = process_deepseek_sse(data, acc, fn(c) { chunks.push(c) })
  assert_false(done)
  assert_eq(chunks.length(), 1)
  assert_true(chunks[0] is @posoco.StreamChunk::TextDelta(token="hello"))
  assert_eq(acc.text, "hello")
}

///|
test "sse_reasoning_delta" {
  let acc = @posoco.StreamAccumulator::new()
  let chunks : Array[@posoco.StreamChunk] = []
  let data = "{\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}"
  let _ = process_deepseek_sse(data, acc, fn(c) { chunks.push(c) })
  assert_eq(chunks.length(), 1)
  assert_true(
    chunks[0] is @posoco.StreamChunk::ReasoningDelta(token="thinking"),
  )
  assert_eq(acc.reasoning, "thinking")
}

///|
test "sse_done_marker" {
  let acc = @posoco.StreamAccumulator::new()
  let chunks : Array[@posoco.StreamChunk] = []
  let done = process_deepseek_sse("[DONE]", acc, fn(c) { chunks.push(c) })
  assert_true(done)
  assert_true(chunks[0] is @posoco.StreamChunk::Finish(_))
}

///|
test "sse_finish_with_usage" {
  let acc = @posoco.StreamAccumulator::new()
  let chunks : Array[@posoco.StreamChunk] = []
  let data =
    #|{"choices":[{"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
  let done = process_deepseek_sse(data, acc, fn(c) { chunks.push(c) })
  assert_true(done)
  // Should emit Usage + Finish
  assert_true(chunks.length() >= 2)
  // Verify usage captured
  let resp = acc.to_response()
  match resp.usage {
    Some(u) =>
      match u.total_tokens {
        Some(n) => assert_eq(n, 15)
        None => fail("expected total_tokens")
      }
    None => fail("expected usage")
  }
  assert_true(resp.finish_reason is @posoco.FinishReason::Stop)
}

///|
test "sse_tool_call_delta" {
  let acc = @posoco.StreamAccumulator::new()
  let chunks : Array[@posoco.StreamChunk] = []
  // First chunk: tool call id + name
  let data1 =
    #|{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_file","arguments":""}}]}}]}
  let _ = process_deepseek_sse(data1, acc, fn(c) { chunks.push(c) })
  // Second chunk: arguments delta
  let data2 =
    #|{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":\"/x\"}"}}]}}]}
  let _ = process_deepseek_sse(data2, acc, fn(c) { chunks.push(c) })
  // Verify accumulator assembled tool call
  let resp = acc.to_response()
  assert_eq(resp.tool_calls.length(), 1)
  assert_eq(resp.tool_calls[0].id, "call_1")
  assert_eq(resp.tool_calls[0].name, "read_file")
  guard resp.tool_calls[0].arguments is Object(args) else {
    fail("expected arguments object")
  }
  match args.get("path") {
    Some(String(p)) => assert_eq(p, "/x")
    _ => fail("expected path argument")
  }
}

///|
/// DeepSeek rule: assistant with tool_calls MUST resend reasoning_content.
/// Verify the encoder emits it when tool_calls present + reasoning_content present.
test "encode_message_reasoning_resent_with_tool_calls" {
  let msg : @posoco.Message = {
    role: @posoco.Role::Assistant,
    content: [],
    tool_calls: [{ id: "c1", name: "read", arguments: Json::object({}) }],
    tool_call_id: None,
    name: None,
    reasoning_content: Some("thinking about this..."),
  }
  let json = encode_message(msg)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning_content") {
    Some(String(r)) => assert_eq(r, "thinking about this...")
    _ => fail("reasoning_content MUST be present when tool_calls exist")
  }
}

///|
/// DeepSeek rule: assistant WITHOUT tool_calls — reasoning_content is omitted
/// even if present (saves tokens, preserves prefix cache).
test "encode_message_reasoning_omitted_without_tool_calls" {
  let msg : @posoco.Message = {
    role: @posoco.Role::Assistant,
    content: [@posoco.Content::Text("answer")],
    tool_calls: [],
    tool_call_id: None,
    name: None,
    reasoning_content: Some("thinking..."),
  }
  let json = encode_message(msg)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning_content") {
    None => () // correct: omitted
    _ => fail("reasoning_content should be omitted for non-tool-call turns")
  }
}

///|
/// DeepSeek rule: tool_calls present but reasoning_content is None — encoder
/// should not add an empty reasoning_content field.
test "encode_message_tool_calls_no_reasoning" {
  let msg : @posoco.Message = {
    role: @posoco.Role::Assistant,
    content: [],
    tool_calls: [{ id: "c1", name: "read", arguments: Json::object({}) }],
    tool_call_id: None,
    name: None,
    reasoning_content: None,
  }
  let json = encode_message(msg)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning_content") {
    None => () // correct: None means don't emit
    _ => fail("should not emit reasoning_content when it's None")
  }
}

///|
test "deepseek_config_defaults_to_single_model" {
  let config = DeepSeekConfig::new("key")
  assert_eq(config.api_key, "key")
  assert_eq(config.base_url, "https://api.deepseek.com")
  assert_eq(config.model, "deepseek-v4-flash")
}

///|
test "deepseek_config_custom_model_passes_through" {
  let config = DeepSeekConfig::new("key", model="custom-model")
  assert_eq(config.model, "custom-model")
}

///|
test "endpoint_helpers_build_api_and_beta_base" {
  let config = DeepSeekConfig::new("key", base_url="https://api.deepseek.com")
  assert_eq(api_base(config), "https://api.deepseek.com")
  assert_eq(beta_base(config), "https://api.deepseek.com/beta")
}

///|
test "beta_base_does_not_duplicate_suffix" {
  let config = DeepSeekConfig::new(
    "key",
    base_url="https://api.deepseek.com/beta",
  )
  assert_eq(beta_base(config), "https://api.deepseek.com/beta")
}

///|
test "build_chat_request_high_thinking_no_warn" {
  let logger = @devkit.MemoryLogger::new()
  let ctx = @devkit.ExtContext::new(logger~)
  let body = build_chat_request(
    ctx,
    [user_msg("hi")],
    [],
    chat_options(Some(High)),
    "deepseek-v4-flash",
    false,
  )
  guard body is Object(root) else { fail("expected object") }
  assert_json_field_string(root, "model", "deepseek-v4-flash")
  guard root.get("thinking") is Some(Object(thinking)) else {
    fail("expected thinking object")
  }
  assert_json_field_string(thinking, "type", "enabled")
  assert_json_field_string(root, "reasoning_effort", "high")
  assert_eq(logger.events.length(), 0)
}

///|
test "build_chat_request_maximum_thinking_no_warn" {
  let logger = @devkit.MemoryLogger::new()
  let ctx = @devkit.ExtContext::new(logger~)
  let body = build_chat_request(
    ctx,
    [user_msg("hi")],
    [],
    chat_options(Some(Maximum)),
    "deepseek-v4-flash",
    false,
  )
  guard body is Object(root) else { fail("expected object") }
  guard root.get("thinking") is Some(Object(thinking)) else {
    fail("expected thinking object")
  }
  assert_json_field_string(thinking, "type", "enabled")
  assert_json_field_string(root, "reasoning_effort", "max")
  assert_eq(logger.events.length(), 0)
}

///|
test "build_chat_request_medium_falls_back_with_warn" {
  let logger = @devkit.MemoryLogger::new()
  let ctx = @devkit.ExtContext::new(logger~)
  let body = build_chat_request(
    ctx,
    [user_msg("hi")],
    [],
    chat_options(Some(Medium)),
    "deepseek-v4-flash",
    false,
  )
  guard body is Object(root) else { fail("expected object") }
  guard root.get("thinking") is Some(Object(thinking)) else {
    fail("expected thinking object")
  }
  assert_json_field_string(thinking, "type", "enabled")
  assert_json_field_string(root, "reasoning_effort", "high")
  assert_eq(logger.events.length(), 1)
  assert_eq(logger.events[0].code, "deepseek.effort_fallback")
  assert_eq(logger.events[0].message, "值不存在已自动路由到high")
}

///|
test "build_chat_request_low_and_minimal_fallback" {
  let logger = @devkit.MemoryLogger::new()
  let ctx = @devkit.ExtContext::new(logger~)
  let _ = build_chat_request(
    ctx,
    [user_msg("hi")],
    [],
    chat_options(Some(Low)),
    "deepseek-v4-flash",
    false,
  )
  let _ = build_chat_request(
    ctx,
    [user_msg("hi")],
    [],
    chat_options(Some(Minimal)),
    "deepseek-v4-flash",
    false,
  )
  assert_eq(logger.events.length(), 2)
  assert_eq(logger.events[0].code, "deepseek.effort_fallback")
  assert_eq(logger.events[1].code, "deepseek.effort_fallback")
}

///|
test "build_chat_request_off_disables_thinking_no_warn" {
  let logger = @devkit.MemoryLogger::new()
  let ctx = @devkit.ExtContext::new(logger~)
  let body = build_chat_request(
    ctx,
    [user_msg("hi")],
    [],
    chat_options(Some(Off)),
    "deepseek-v4-flash",
    false,
  )
  guard body is Object(root) else { fail("expected object") }
  guard root.get("thinking") is Some(Object(thinking)) else {
    fail("expected thinking object")
  }
  assert_json_field_string(thinking, "type", "disabled")
  match root.get("reasoning_effort") {
    None => ()
    _ => fail("disabled thinking should omit reasoning_effort")
  }
  assert_eq(logger.events.length(), 0)
}

///|
test "build_chat_request_named_tool_choice" {
  let ctx = @devkit.ExtContext::default()
  let options : @posoco.ChatOptions = {
    temperature: None,
    max_output_tokens: None,
    tool_choice: Some(@posoco.ToolChoice::NamedTool("read")),
    reasoning_effort: Some(@posoco.ReasoningEffort::Off),
  }
  let body = build_chat_request(
    ctx,
    [user_msg("hi")],
    [],
    options,
    "deepseek-v4-flash",
    false,
  )
  guard body is Object(root) else { fail("expected object") }
  guard root.get("tool_choice") is Some(Object(choice)) else {
    fail("expected named tool choice")
  }
  assert_json_field_string(choice, "type", "function")
  guard choice.get("function") is Some(Object(function)) else {
    fail("expected function choice")
  }
  assert_json_field_string(function, "name", "read")
}

///|
test "fim_request_body_uses_config_model" {
  let config = DeepSeekConfig::new("key", model="same-model")
  let body = build_fim_request_body(config, "prefix", Some("suffix"), 64)
  guard body is Object(root) else { fail("expected object") }
  assert_json_field_string(root, "model", "same-model")
  assert_json_field_string(root, "prompt", "prefix")
  assert_json_field_string(root, "suffix", "suffix")
}

///|
test "prefix_request_body_uses_config_model_and_appends_prefix" {
  let config = DeepSeekConfig::new("key", model="same-model")
  let body = build_prefix_request_body(
    config,
    [user_msg("hi")],
    "```json\n",
    Some(["```"]),
  )
  guard body is Object(root) else { fail("expected object") }
  assert_json_field_string(root, "model", "same-model")
  guard root.get("messages") is Some(Array(messages)) else {
    fail("expected messages")
  }
  assert_eq(messages.length(), 2)
  guard messages[1] is Object(prefix_msg) else { fail("expected prefix msg") }
  assert_json_field_string(prefix_msg, "role", "assistant")
  assert_json_field_string(prefix_msg, "content", "```json\n")
  match prefix_msg.get("prefix") {
    Some(True) => ()
    _ => fail("expected prefix=true")
  }
}
