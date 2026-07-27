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
    Err(@posoco.ModelError::Transport(msg)) => {
      assert_true(msg.contains("stage=response.error"))
      assert_false(msg.contains("Invalid API key"))
    }
    Err(_) => fail("expected Transport error")
    Ok(_) => fail("expected error")
  }
}

///|
/// SSE parser tests — process_deepseek_sse is pure (no network).

///|
test "sse_text_delta" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
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
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
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
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let done = process_deepseek_sse("[DONE]", acc, fn(c) { chunks.push(c) })
  assert_true(done)
  assert_true(chunks[0] is @posoco.StreamChunk::Finish(_))
}

///|
test "sse_finish_with_usage" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
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
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
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
    tool_calls: [{ id: "c1", name: "read", arguments: Json::empty_object() }],
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
    tool_calls: [{ id: "c1", name: "read", arguments: Json::empty_object() }],
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
test "endpoint_helpers_build_chat_and_fim_url" {
  let config = DeepSeekConfig::new("key", base_url="https://api.deepseek.com")
  assert_eq(chat_url(config), "https://api.deepseek.com/chat/completions")
  assert_eq(fim_url(config), "https://api.deepseek.com/beta/completions")
}

///|
test "fim_url_does_not_duplicate_suffix" {
  let config = DeepSeekConfig::new(
    "key",
    base_url="https://api.deepseek.com/beta",
  )
  assert_eq(fim_url(config), "https://api.deepseek.com/beta/completions")
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

// ---------------------------------------------------------------------------
// M0-T07-B: error-transparency fixtures (offline, no network).
// These use non-async test blocks with try/catch since decode_chat_response
// is synchronous but raises ModelError.
// ---------------------------------------------------------------------------

///|
/// Build a tool-call entry JSON object with the given arguments string.
fn build_tool_call_json(id : String, name : String, args_str : String) -> Json {
  Json::object(
    Map::from_array([
      ("id", Json::string(id)),
      ("type", Json::string("function")),
      (
        "function",
        Json::object(
          Map::from_array([
            ("name", Json::string(name)),
            ("arguments", Json::string(args_str)),
          ]),
        ),
      ),
    ]),
  )
}

///|
/// T07-B: malformed tool-call arguments JSON must raise ResponseParse,
/// not silently become {}.
test "t07b_deepseek_malformed_tool_args_raises" {
  let bad_call = build_tool_call_json("tc_1", "bad", "not-valid-json")
  let resp_json = Json::object(
    Map::from_array([
      (
        "choices",
        Json::array([
          Json::object(
            Map::from_array([
              (
                "message",
                Json::object(
                  Map::from_array([
                    ("role", Json::string("assistant")),
                    ("content", Json::string("")),
                    ("tool_calls", Json::array([bad_call])),
                  ]),
                ),
              ),
              ("finish_reason", Json::string("tool_calls")),
            ]),
          ),
        ]),
      ),
    ]),
  )
  let result = Ok(decode_chat_response(resp_json)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(_)) => ()
    _ => fail("expected ResponseParse for malformed tool arguments")
  }
}

///|
/// T07-B: valid tool-call arguments still decode correctly (no false positive).
test "t07b_deepseek_valid_tool_args_still_decode" {
  let ok_call = build_tool_call_json("tc_1", "ok", "{}")
  let resp_json = Json::object(
    Map::from_array([
      (
        "choices",
        Json::array([
          Json::object(
            Map::from_array([
              (
                "message",
                Json::object(
                  Map::from_array([
                    ("role", Json::string("assistant")),
                    ("content", Json::string("")),
                    ("tool_calls", Json::array([ok_call])),
                  ]),
                ),
              ),
              ("finish_reason", Json::string("tool_calls")),
            ]),
          ),
        ]),
      ),
    ]),
  )
  let resp = decode_chat_response(resp_json)
  assert_eq(resp.tool_calls.length(), 1)
  assert_eq(resp.tool_calls[0].name, "ok")
}

///|
test "t07b_deepseek_malformed_sse_is_loud_and_redacted" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let secret = "secret-sse-payload"
  let result = Ok(process_deepseek_sse(secret, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) => {
      assert_true(msg.contains("stage=json"))
      assert_false(msg.contains(secret))
    }
    _ => fail("expected ResponseParse for malformed SSE JSON")
  }
}

///|
test "t07b_deepseek_missing_sse_structure_is_loud" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let missing_choices =
    #|{"id":"response_without_choices"}
  let result = Ok(process_deepseek_sse(missing_choices, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("stage=choices"))
    _ => fail("expected ResponseParse for missing choices")
  }
}

///|
test "t07b_deepseek_wrong_type_tool_field_is_loud" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let bad_name =
    #|{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":7,"arguments":"{}"}}]}}]}
  let result = Ok(process_deepseek_sse(bad_name, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("stage=tool.name"))
    _ => fail("expected ResponseParse for wrong-type tool name")
  }
}

///|
test "t07b_deepseek_stream_termination_is_protocol_driven" {
  assert_true(classify_deepseek_stream_termination(ExplicitTerminal) is None)
  match classify_deepseek_stream_termination(CleanEof) {
    Some(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("terminal_marker=missing"))
    _ => fail("clean EOF before terminal marker must be ResponseParse")
  }
  match classify_deepseek_stream_termination(TransportFailure) {
    Some(@posoco.ModelError::Transport(msg)) =>
      assert_true(msg.contains("stage=read_stream"))
    _ => fail("read failure must be Transport")
  }
}

///|
test "t07b_deepseek_tool_argument_error_does_not_echo_payload" {
  let secret = "secret-tool-arguments"
  let bad_call = build_tool_call_json("tc_1", "bad", secret)
  let resp_json = Json::object(
    Map::from_array([
      (
        "choices",
        Json::array([
          Json::object(
            Map::from_array([
              (
                "message",
                Json::object(
                  Map::from_array([
                    ("role", Json::string("assistant")),
                    ("content", Json::string("")),
                    ("tool_calls", Json::array([bad_call])),
                  ]),
                ),
              ),
            ]),
          ),
        ]),
      ),
    ]),
  )
  let result = Ok(decode_chat_response(resp_json)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) => {
      assert_true(msg.contains("payload_chars="))
      assert_false(msg.contains(secret))
    }
    _ => fail("expected redacted ResponseParse")
  }
}

///|
test "t07b_deepseek_missing_nonstream_tool_arguments_is_loud" {
  let bad_call : Json = {
    "id": "tc_1",
    "type": "function",
    "function": { "name": "missing_args" },
  }
  let resp_json : Json = {
    "choices": [
      {
        "message": {
          "role": "assistant",
          "content": "",
          "tool_calls": [bad_call],
        },
      },
    ],
  }
  let result = Ok(decode_chat_response(resp_json)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("stage=tool.arguments"))
    _ => fail("expected ResponseParse for missing tool arguments")
  }
}

///|
test "t07b_deepseek_stream_tool_argument_error_is_redacted" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let secret = "secret-stream-tool-arguments"
  acc.push(
    @posoco.StreamChunk::ToolCallDelta(
      index=0,
      id=Some("call_1"),
      name=Some("bad"),
      arguments_delta=Some(secret),
    ),
  )
  let result = Ok(validate_deepseek_stream_tool_calls(acc)) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) => {
      assert_true(msg.contains("payload_chars="))
      assert_false(msg.contains(secret))
    }
    _ => fail("expected redacted stream argument error")
  }
}

///|
fn assert_deepseek_response_parse(resp : Json, stage : String) -> Unit raise {
  let result = Ok(decode_chat_response(resp)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stage=" + stage))
    _ => fail("expected DeepSeek ResponseParse at " + stage)
  }
}

///|
test "t07b_deepseek_nonobject_response_is_response_parse" {
  assert_deepseek_response_parse(Json::array([]), "response")
}

///|
fn assert_deepseek_response_parse_category(
  response : Json,
  stage : String,
  category : String,
) -> Unit raise {
  let result = Ok(decode_chat_response(response)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("stage=" + stage))
      assert_true(message.contains("category=" + category))
      assert_false(message.contains("secret-provider-body"))
    }
    _ => fail("expected DeepSeek ResponseParse at " + stage)
  }
}

///|
test "t07b_deepseek_chat_response_shapes_are_structured_and_redacted" {
  assert_deepseek_response_parse_category(
    Json::empty_object(),
    "choices",
    "missing",
  )
  assert_deepseek_response_parse_category(
    Json::object({ "choices": Json::string("secret-provider-body") }),
    "choices",
    "wrong_type",
  )
  assert_deepseek_response_parse_category(
    Json::object({ "choices": Json::array([]) }),
    "choices",
    "empty",
  )
  assert_deepseek_response_parse_category(
    Json::object({ "choices": Json::array([Json::string("invalid")]) }),
    "choice",
    "not_object",
  )
  assert_deepseek_response_parse_category(
    Json::object({ "choices": Json::array([Json::empty_object()]) }),
    "message",
    "missing",
  )
}

///|
test "t07b_deepseek_reasoning_content_is_strict" {
  let response : Json = {
    "choices": [
      {
        "message": {
          "role": "assistant",
          "content": "ok",
          "reasoning_content": 7,
        },
        "finish_reason": "stop",
      },
    ],
  }
  assert_deepseek_response_parse(response, "message.reasoning_content")
}

///|
test "t07b_deepseek_finish_reason_is_required_and_typed" {
  let missing : Json = {
    "choices": [{ "message": { "role": "assistant", "content": "ok" } }],
  }
  assert_deepseek_response_parse(missing, "finish_reason")
  let wrong_type : Json = {
    "choices": [
      {
        "message": { "role": "assistant", "content": "ok" },
        "finish_reason": 7,
      },
    ],
  }
  assert_deepseek_response_parse(wrong_type, "finish_reason")
}

///|
test "t07b_deepseek_nonstream_usage_is_strict" {
  let wrong_type : Json = {
    "choices": [
      {
        "message": { "role": "assistant", "content": "ok" },
        "finish_reason": "stop",
      },
    ],
    "usage": {
      "prompt_tokens": "secret",
      "completion_tokens": 1,
      "total_tokens": 2,
    },
  }
  assert_deepseek_response_parse(wrong_type, "usage.prompt_tokens")
  let missing_field : Json = {
    "choices": [
      {
        "message": { "role": "assistant", "content": "ok" },
        "finish_reason": "stop",
      },
    ],
    "usage": { "prompt_tokens": 1, "completion_tokens": 1 },
  }
  assert_deepseek_response_parse(missing_field, "usage.total_tokens")
}

///|
test "t07b_deepseek_valid_nonstream_response_still_decodes" {
  let response : Json = {
    "choices": [
      {
        "message": {
          "role": "assistant",
          "content": "ok",
          "reasoning_content": "checked",
        },
        "finish_reason": "stop",
      },
    ],
    "usage": { "prompt_tokens": 2, "completion_tokens": 1, "total_tokens": 3 },
  }
  let decoded = decode_chat_response(response)
  assert_true(decoded.finish_reason is @posoco.FinishReason::Stop)
  assert_true(decoded.reasoning_content == Some("checked"))
  match decoded.usage {
    Some(usage) => {
      assert_true(usage.input_tokens == Some(2))
      assert_true(usage.output_tokens == Some(1))
      assert_true(usage.total_tokens == Some(3))
    }
    None => fail("expected decoded usage")
  }
}

///|
test "t07b_deepseek_http_error_formatter_is_payload_free" {
  let message = format_deepseek_http_error(
    "fim.http_status",
    429,
    BodyBytesUtf8(19),
  )
  assert_eq(
    message, "DeepSeek HTTP error (stage=fim.http_status, status=429, body_bytes=19, body_category=utf8)",
  )
  assert_false(message.contains("secret-response-body"))
}

///|
fn assert_deepseek_sse_response_parse(
  data : String,
  stage : String,
  category : String,
) -> Unit raise {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let result = Ok(process_deepseek_sse(data, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("stage=" + stage))
      assert_true(message.contains("category=" + category))
    }
    _ => fail("expected DeepSeek SSE ResponseParse at " + stage)
  }
}

///|
test "t07b_deepseek_stream_usage_fields_are_required" {
  assert_deepseek_sse_response_parse(
    "{\"usage\":{\"completion_tokens\":2,\"total_tokens\":3}}", "usage.prompt_tokens",
    "missing",
  )
  assert_deepseek_sse_response_parse(
    "{\"usage\":{\"prompt_tokens\":1,\"total_tokens\":3}}", "usage.completion_tokens",
    "missing",
  )
  assert_deepseek_sse_response_parse(
    "{\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2}}", "usage.total_tokens",
    "missing",
  )
}

///|
test "t07b_deepseek_stream_usage_fields_are_typed" {
  assert_deepseek_sse_response_parse(
    "{\"usage\":{\"prompt_tokens\":\"secret\",\"completion_tokens\":2,\"total_tokens\":3}}",
    "usage.prompt_tokens", "wrong_type",
  )
  assert_deepseek_sse_response_parse(
    "{\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":false,\"total_tokens\":3}}",
    "usage.completion_tokens", "wrong_type",
  )
  assert_deepseek_sse_response_parse(
    "{\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":null}}",
    "usage.total_tokens", "wrong_type",
  )
}

///|
test "t07b_deepseek_valid_stream_usage_still_decodes" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let done = process_deepseek_sse(
    "{\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}",
    acc,
    fn(chunk) { chunks.push(chunk) },
  )
  assert_false(done)
  assert_eq(chunks.length(), 1)
  assert_true(
    chunks[0]
    is @posoco.StreamChunk::Usage(
      { input_tokens: Some(1), output_tokens: Some(2), total_tokens: Some(3) }
    ),
  )
}

///|
fn assert_deepseek_http_error_summary(
  summary : DeepSeekErrorBodySummary,
  expected : String,
) -> Unit raise {
  match classify_deepseek_http_status("prefix.http_status", 503, summary) {
    Some(@posoco.ModelError::Transport(message)) => {
      assert_true(message.contains("status=503"))
      assert_true(message.contains(expected))
      assert_false(message.contains("secret-provider-body"))
    }
    _ => fail("non-2xx response must be Transport")
  }
}

///|
test "t07b_deepseek_http_status_classifier_preserves_status_and_redacts_body" {
  assert_true(
    classify_deepseek_http_status(
      "chat.http_status",
      200,
      BodyBytesInvalidUtf8(11),
    )
    is None,
  )
  assert_true(
    classify_deepseek_http_status("chat.http_status", 204, BodyBytesUtf8(0))
    is None,
  )
  assert_deepseek_http_error_summary(
    BodyBytesUtf8(13),
    "body_bytes=13, body_category=utf8",
  )
  assert_deepseek_http_error_summary(
    BodyBytesInvalidUtf8(11),
    "body_bytes=11, body_category=invalid_utf8",
  )
  assert_deepseek_http_error_summary(
    BodyReadFailed,
    "body_category=read_failed",
  )
}

///|
fn assert_fim_response_parse(
  response : Json,
  stage : String,
  category : String,
) -> Unit raise {
  let result = Ok(decode_fim_response(response)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("stage=" + stage))
      assert_true(message.contains("category=" + category))
      assert_false(message.contains("secret-provider-body"))
    }
    _ => fail("expected FIM ResponseParse at " + stage)
  }
}

///|
test "t07b_deepseek_fim_response_shapes_are_strict_and_redacted" {
  assert_fim_response_parse(Json::array([]), "fim.response", "not_object")
  assert_fim_response_parse(Json::empty_object(), "fim.choices", "missing")
  assert_fim_response_parse(
    Json::object({ "choices": Json::string("secret-provider-body") }),
    "fim.choices",
    "wrong_type",
  )
  assert_fim_response_parse(
    Json::object({ "choices": Json::array([]) }),
    "fim.choices",
    "empty",
  )
  assert_fim_response_parse(
    Json::object({ "choices": Json::array([Json::string("invalid")]) }),
    "fim.choice",
    "not_object",
  )
  assert_fim_response_parse(
    Json::object({ "choices": Json::array([Json::empty_object()]) }),
    "fim.choice.text",
    "missing",
  )
  assert_fim_response_parse(
    Json::object({
      "choices": Json::array([Json::object({ "text": Json::number(7.0) })]),
    }),
    "fim.choice.text",
    "wrong_type",
  )
}

///|
test "t07b_deepseek_valid_fim_response_still_decodes" {
  assert_eq(
    decode_fim_response(
      Json::object({
        "choices": Json::array([
          Json::object({ "text": Json::string("middle") }),
        ]),
      }),
    ),
    "middle",
  )
}

///|
/// `moon fmt` marks async documentation snippets as `nocheck`. Keep their
/// exact public call shapes type-checked here without performing HTTP I/O.
async test "t08_deepseek_public_fim_examples_compile" {
  @async.protect_from_cancel(() => ())
  let port = DeepSeekModelPort::new(DeepSeekConfig::new("fixture-key"))
  let messages : Array[@posoco.Message] = [
    {
      role: @posoco.Role::User,
      content: [@posoco.Content::Text("output JSON")],
      tool_calls: [],
      tool_call_id: None,
      name: None,
      reasoning_content: None,
    },
  ]
  if false {
    let _ = port.fim_completion(
      "def fib(a):\n  if a <= 1: return a\n  ",
      Some("return fib(a-1) + fib(a-2)"),
    )
    let _ = port.chat_prefix_completion(messages, "```json\n", Some(["```"]))
  }
}
