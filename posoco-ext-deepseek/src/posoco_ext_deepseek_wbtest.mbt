///|
/// Blackbox tests for posoco-ext-deepseek wire encoding/decoding.
/// These test the pure encode/decode logic without any network calls.

///|
fn disabled_thinking_json() -> Json {
  Json::object({ "type": Json::string("disabled") })
}

///|
fn user_msg(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
fn assistant_msg(text : String) -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
}

///|
fn chat_options() -> @posoco.ChatOptions {
  { temperature: None, max_output_tokens: None, }
}

///|
/// Provider-neutral prompt fake used to exercise DeepSeek's API-key seam.
struct DeepSeekApiKeyPrompt {
  value : String
}

///|
pub impl @oauth.AuthPromptInteraction for DeepSeekApiKeyPrompt with fn prompt(
  self : DeepSeekApiKeyPrompt,
  _request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  self.value
}

///|
async test "DeepSeek API-key factory validates and returns an opaque credential" {
  let provider = DeepSeekProvider()
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = DeepSeekApiKeyPrompt::{ value: "deepseek-secret", }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let credential = api.login(prompt)
  assert_eq(credential.secret, "deepseek-secret")
}

///|
async test "DeepSeek API-key factory rejects an empty secret" {
  let provider = DeepSeekProvider()
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = DeepSeekApiKeyPrompt::{ value: "", }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let result = Ok(api.login(prompt)) catch { error => Err(error) }
  match result {
    Err(@oauth.OAuthError::ParseError(message)) =>
      assert_true(message.contains("must not be empty"))
    _ => fail("expected empty DeepSeek API key to fail")
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
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[],
    tool_calls=[
      {
        call_id: @posoco.CallId::unchecked("call_1"),
        name: @posoco.ToolName::unchecked("read_file"),
        arguments: Json::object({ "path": Json::string("/tmp/x") }),
      },
    ],
    reasoning=None,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
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
  assert_eq(resp.message.content.length(), 1)
  match resp.message.content[0] {
    Text(t) => assert_eq(t, "hello world")
    _ => fail("expected Text content")
  }
  // Verify finish reason (method, not field)
  assert_true(resp.finish_reason() is @posoco.FinishReason::Stop)
  match resp.usage {
    Some(u) =>
      match u.total_tokens {
        Some(n) => assert_eq(n, 15)
        None => fail("expected total_tokens")
      }
    None => fail("expected usage")
  }
  // Verify no reasoning (basic chat has none)
  match resp.message.reasoning {
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
  match resp.message.reasoning {
    Some(r) => assert_eq(r.content, "let me think...")
    None => fail("expected reasoning")
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
  let tcs = resp.tool_calls()
  assert_eq(tcs.length(), 1)
  let tc = tcs[0]
  assert_eq(tc.call_id.to_string(), "call_1")
  assert_eq(tc.name.to_string(), "read_file")
  // arguments should be parsed JSON
  guard tc.arguments is Object(args) else { fail("expected arguments object") }
  match args.get("path") {
    Some(String(p)) => assert_eq(p, "/tmp/x")
    _ => fail("expected path argument")
  }
  assert_true(resp.finish_reason() is @posoco.FinishReason::ToolCalls)
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
  assert_eq(acc.text(), "hello")
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
  assert_eq(acc.reasoning(), "thinking")
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
  // Verify usage captured on the accumulator
  assert_true(acc.usage_total == Some(15))
  let resp = acc.to_completion()
  assert_true(resp.finish_reason() is @posoco.FinishReason::Stop)
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
  let resp = acc.to_completion()
  let tcs = resp.tool_calls()
  assert_eq(tcs.length(), 1)
  assert_eq(tcs[0].call_id.to_string(), "call_1")
  assert_eq(tcs[0].name.to_string(), "read_file")
  guard tcs[0].arguments is Object(args) else {
    fail("expected arguments object")
  }
  match args.get("path") {
    Some(String(p)) => assert_eq(p, "/x")
    _ => fail("expected path argument")
  }
}

///|
/// Regression guard for the double-push bug: when a caller drives
/// process_deepseek_sse with a production-style callback (one that forwards
/// to a host AND accumulates), each delta must land in the accumulator
/// exactly once. The bridge in deepseek.mbt previously called acc.push inside
/// on_typed while process_deepseek_sse also pushed, doubling every text and
/// reasoning token (and corrupting tool-call argument JSON).
///
/// This test mirrors the real wiring: the callback forwards the chunk (as a
/// would-be Json) and, to be safe against the same regression, does NOT push
/// to acc itself — the parser owns accumulation. If either side regresses and
/// pushes twice, acc.text / acc.reasoning will be doubled.
test "sse_no_double_push_with_forwarding_callback" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let forwarded : Array[@posoco.StreamChunk] = []
  // Production-style callback: forward the chunk to the host. Accumulation is
  // owned by process_deepseek_sse; the callback must not also push.
  let on_typed = fn(c : @posoco.StreamChunk) { forwarded.push(c) }
  let text_data =
    #|{"choices":[{"delta":{"content":"早上好"}}]}
  let reasoning_data =
    #|{"choices":[{"delta":{"reasoning_content":"思考中"}}]}
  let _ = process_deepseek_sse(text_data, acc, on_typed)
  let _ = process_deepseek_sse(reasoning_data, acc, on_typed)
  // Each token forwarded exactly once to the host.
  assert_eq(forwarded.length(), 2)
  // Each token accumulated exactly once — NOT doubled.
  assert_eq(acc.text(), "早上好")
  assert_eq(acc.reasoning(), "思考中")
}

///|
/// DeepSeek rule: assistant with tool_calls MUST resend reasoning_content.
/// Verify the encoder emits it when tool_calls present + reasoning present.
test "encode_message_reasoning_resent_with_tool_calls" {
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[],
    tool_calls=[
      {
        call_id: @posoco.CallId::unchecked("c1"),
        name: @posoco.ToolName::unchecked("read"),
        arguments: Json::empty_object(),
      },
    ],
    reasoning=Some(@posoco.Reasoning::{
      content: "thinking about this...",
      raw: None,
    }),
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
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
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=Some(@posoco.Reasoning::{ content: "thinking...", raw: None, }),
    finish_reason=@posoco.FinishReason::Stop,
  )
  let json = encode_message(msg)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning_content") {
    None => () // correct: omitted
    _ => fail("reasoning_content should be omitted for non-tool-call turns")
  }
}

///|
/// DeepSeek rule: tool_calls present but reasoning is None — encoder
/// should not add an empty reasoning_content field.
test "encode_message_tool_calls_no_reasoning" {
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[],
    tool_calls=[
      {
        call_id: @posoco.CallId::unchecked("c1"),
        name: @posoco.ToolName::unchecked("read"),
        arguments: Json::empty_object(),
      },
    ],
    reasoning=None,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let json = encode_message(msg)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning_content") {
    None => () // correct: None means don't emit
    _ => fail("should not emit reasoning_content when it's None")
  }
}

///|
/// Tool-role messages MUST carry `tool_call_id` — the correlation key for the
/// assistant tool_call they answer (OpenAI-compatible convention; verified
/// against opencode-zen 2026-08).
test "encode_message_tool_result_carries_tool_call_id" {
  let msg : @posoco.Message = @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_42"),
    tool_name=@posoco.ToolName::unchecked("read_file"),
    outcome=@posoco.ToolOutcome::Success(
      content="file contents",
      structured=None,
    ),
  )
  let json = encode_message(msg)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("role") {
    Some(String(r)) => assert_eq(r, "tool")
    _ => fail("expected tool role")
  }
  match obj.get("tool_call_id") {
    Some(String(id)) => assert_eq(id, "call_42")
    _ => fail("tool message MUST carry tool_call_id")
  }
  match obj.get("content") {
    Some(String(c)) => assert_eq(c, "file contents")
    _ => fail("expected outcome text as content")
  }
}

///|
test "deepseek_config_defaults_to_single_model" {
  let config = DeepSeekConfig("key")
  assert_eq(config.api_key, "key")
  assert_eq(config.base_url, "https://api.deepseek.com")
  assert_eq(config.model, "deepseek-v4-flash")
}

///|
test "deepseek_config_custom_model_passes_through" {
  let config = DeepSeekConfig("key", model="custom-model")
  assert_eq(config.model, "custom-model")
}

///|
test "endpoint_helpers_build_chat_and_fim_url" {
  let config = DeepSeekConfig("key", base_url="https://api.deepseek.com")
  assert_eq(chat_url(config), "https://api.deepseek.com/chat/completions")
  assert_eq(fim_url(config), "https://api.deepseek.com/beta/completions")
}

///|
test "fim_url_does_not_duplicate_suffix" {
  let config = DeepSeekConfig("key", base_url="https://api.deepseek.com/beta")
  assert_eq(fim_url(config), "https://api.deepseek.com/beta/completions")
}

///|
/// build_chat_request takes thinking_json + effort_str directly now; the
/// high-effort path passes them through without warning.
test "build_chat_request_high_thinking_no_warn" {
  let logger = @devkit.MemoryLogger()
  let ctx = @devkit.ExtContext(logger~)
  let body = build_chat_request(
    ctx,
    [user_msg("hi")],
    [],
    chat_options(),
    "deepseek-v4-flash",
    false,
    enabled_thinking_json(),
    Some("high"),
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
  let logger = @devkit.MemoryLogger()
  let ctx = @devkit.ExtContext(logger~)
  let body = build_chat_request(
    ctx,
    [user_msg("hi")],
    [],
    chat_options(),
    "deepseek-v4-flash",
    false,
    enabled_thinking_json(),
    Some("max"),
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
test "build_chat_request_off_disables_thinking_no_warn" {
  let logger = @devkit.MemoryLogger()
  let ctx = @devkit.ExtContext(logger~)
  let body = build_chat_request(
    ctx,
    [user_msg("hi")],
    [],
    chat_options(),
    "deepseek-v4-flash",
    false,
    disabled_thinking_json(),
    None,
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
test "fim_request_body_uses_config_model" {
  let config = DeepSeekConfig("key", model="same-model")
  let body = build_fim_request_body(config, "prefix", Some("suffix"), 64)
  guard body is Object(root) else { fail("expected object") }
  assert_json_field_string(root, "model", "same-model")
  assert_json_field_string(root, "prompt", "prefix")
  assert_json_field_string(root, "suffix", "suffix")
}

///|
test "prefix_request_body_uses_config_model_and_appends_prefix" {
  let config = DeepSeekConfig("key", model="same-model")
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

// Error-transparency fixtures (offline, no network). decode_chat_response is
// synchronous but raises ModelError, so these use try/catch.

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
/// Malformed tool-call arguments JSON must raise ResponseParse,
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
/// Valid tool-call arguments still decode correctly (no false positive).
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
  let tcs = resp.tool_calls()
  assert_eq(tcs.length(), 1)
  assert_eq(tcs[0].name.to_string(), "ok")
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
test "t07b_deepseek_content_free_chunk_is_skipped" {
  // No choices/usage/error keys: a preamble or keepalive chunk carries no
  // content; skipping it must not fail the stream (policy moved to the
  // shared posoco-kit-chat-completions parser).
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let content_free =
    #|{"id":"response_without_choices"}
  let done = process_deepseek_sse(content_free, acc, fn(_) { () })
  assert_false(done)
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
  assert_true(decoded.finish_reason() is @posoco.FinishReason::Stop)
  assert_true(
    decoded.message.reasoning ==
    Some(@posoco.Reasoning::{ content: "checked", raw: None, }),
  )
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
  // StreamChunk::Usage carries positional token counts (not a Usage struct).
  assert_true(
    chunks[0]
    is @posoco.StreamChunk::Usage(
      input_tokens=1,
      output_tokens=2,
      total_tokens=3,
      ..
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
  let port = DeepSeekModelPort(DeepSeekConfig("fixture-key"))
  let messages : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("output JSON")]),
  ]
  if false {
    let _ = port.fim_completion(
      "def fib(a):\n  if a <= 1: return a\n  ",
      Some("return fib(a-1) + fib(a-2)"),
    )
    let _ = port.chat_prefix_completion(messages, "```json\n", Some(["```"]))
  }
}

///|
test "DeepSeekConfig::with_reasoning_effort maps off to empty and validates membership" {
  let config = DeepSeekConfig("sk-test", reasoning_effort="high")
  assert_eq(config.with_reasoning_effort("off").reasoning_effort, "")
  assert_eq(config.with_reasoning_effort("max").reasoning_effort, "max")
  let invalid = Ok(config.with_reasoning_effort("low")) catch {
    err => Err(err)
  }
  match invalid {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("unsupported reasoning effort"))
    _ => fail("an undeclared effort must fail at the config boundary")
  }
}

///|
test "default_thinking_config disables thinking whenever the effort is empty" {
  let config = DeepSeekConfig("sk-test", reasoning_effort="")
  let port = DeepSeekModelPort(config)
  let (thinking, effort) = port.default_thinking_config()
  guard thinking is Json::Object({ "type": Json::String("disabled"), .. }) else {
    fail("an empty effort must emit disabled thinking")
  }
  assert_eq(effort, None)
}

///|
test "model_catalog slot advertises an implicit off and derives the default effort" {
  let config = DeepSeekConfig("sk-test", reasoning_effort="high")
  let port = DeepSeekModelPort(config)
  let catalog = port.model_catalog()
  let slot = catalog.slots()[0]
  assert_eq(slot.thinking_efforts, ["off", "high", "max"])
  assert_eq(slot.default_effort, Some("high"))
  guard slot.rebuild_on_effort is Some(rebuild) else {
    fail("a reasoning model must expose an effort rebuild hook")
  }
  let rebuilt = rebuild("off")
  assert_eq(rebuilt.thinking_efforts, ["off", "high", "max"])
  assert_eq(rebuilt.default_effort, Some("off"))
}

///|
test "ProviderFactory::build accepts reasoning_effort off and produces a disabled slot" {
  let provider = DeepSeekProvider()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-test")),
          ("reasoning_effort", Json::string("off")),
        ]),
      ),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      assert_eq(slot.thinking_efforts, ["off", "high", "max"])
      assert_eq(slot.default_effort, Some("off"))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with reasoning_effort off")
  }
}

///|
/// The host-cached record shape: a previous refresh projected to slot
/// records. DeepSeek consumes only `model_id` and re-derives its reasoning
/// policy, so the expanded catalog matches the live-refresh catalog.
fn deepseek_cached_records(ids : Array[String]) -> Json {
  let items : Array[Json] = []
  for id in ids {
    items.push(
      Json::object(
        Map::from_array([
          ("model_id", Json::string(id)),
          ("thinking_efforts", Json::array([])),
          ("default_effort", Json::null()),
        ]),
      ),
    )
  }
  Json::array(items)
}

///|
test "ProviderFactory::build expands host-cached records into a multi-slot catalog" {
  let provider = DeepSeekProvider()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-test")),
          ("model", Json::string("deepseek-chat")),
        ]),
      ),
    ),
    cached_models=Some(
      deepseek_cached_records(["deepseek-chat", "deepseek-reasoner"]),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slots = catalog.slots()
      assert_eq(slots.length(), 2)
      // The configured model is pinned first; reasoning profiles are
      // re-derived from ids exactly as the live refresh would.
      assert_eq(slots[0].id, "deepseek/deepseek-chat")
      assert_eq(slots[1].id, "deepseek/deepseek-reasoner")
      assert_eq(slots[1].thinking_efforts, ["off", "high", "max"])
      assert_eq(slots[1].default_effort, Some("high"))
      assert_eq(slots[0].thinking_efforts, [])
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog from cached records")
  }
}

///|
test "ProviderFactory::build degrades to the static slot on bad cached records" {
  let provider = DeepSeekProvider()
  let factory : &@llm.ProviderFactory = provider
  for
    bad in [
      Json::array([]),
      Json::string("nope"),
      Json::array([Json::number(1.0)]),
      Json::array([
        Json::object(
          Map::from_array([("model_id", Json::string("deepseek-chat"))]),
        ),
        Json::object(Map::from_array([("model_id", Json::null())])),
      ]),
    ] {
    let source = @llm.ProviderConfigSource::ProviderConfigSource(
      settings=Some(
        Json::object(Map::from_array([("api_key", Json::string("sk-test"))])),
      ),
      cached_models=Some(bad),
    )
    match factory.build(source) {
      @llm.ProviderBuildResult::Ready(catalog) => {
        let slots = catalog.slots()
        assert_true(slots.length() == 1)
        assert_eq(slots[0].model_id, "deepseek-v4-flash")
      }
      @llm.ProviderBuildResult::Unconfigured =>
        fail(
          "bad cache records must degrade to the static build, not Unconfigured",
        )
    }
  }
}

///|
test "decode_chat_response extracts DeepSeek prompt_cache_hit_tokens" {
  let resp_json : Json = {
    "choices": [
      {
        "message": { "role": "assistant", "content": "ok" },
        "finish_reason": "stop",
      },
    ],
    "usage": {
      "prompt_tokens": 1200,
      "completion_tokens": 5,
      "total_tokens": 1205,
      "prompt_cache_hit_tokens": 1000,
      "prompt_cache_miss_tokens": 200,
    },
  }
  let resp = decode_chat_response(resp_json)
  match resp.usage {
    Some(u) => {
      assert_eq(u.input_tokens, Some(1200))
      assert_eq(u.cached_input_tokens, Some(1000))
      // DeepSeek reports hit and miss as a pair; consumers never derive.
      assert_eq(u.uncached_input_tokens, Some(200))
    }
    None => fail("expected usage")
  }
}

///|
fn dsc_tool_msg(text : String) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_1"),
    tool_name=@posoco.ToolName::unchecked("read"),
    outcome=@posoco.ToolOutcome::Success(content=text, structured=None),
  )
}

///|
test "ds_compact_split keeps the tail aligned on a user boundary" {
  let messages = [
    user_msg("one"),
    assistant_msg("two"),
    dsc_tool_msg("t1"),
    user_msg("three"),
    assistant_msg("four"),
  ]
  // The short transcript never reaches the 20k budget: nothing to summarize.
  assert_true(ds_compact_split(messages) is None)
}

///|
test "ds_compact_split never splits an assistant from its tool results" {
  // A ~21000-token second user turn crosses the 20k budget exactly at its
  // own boundary (candidate lands ON a UserMessage at index 2), so the head
  // keeps the first turn and the tail starts at the second.
  let big = "detail ".repeat(12000)
  let messages = [
    user_msg(big),
    assistant_msg("ok"),
    user_msg(big),
    assistant_msg("ok"),
    user_msg("recent"),
    assistant_msg("recent answer"),
  ]
  guard ds_compact_split(messages) is Some((head, tail)) else {
    fail("expected a split")
  }
  // The tail must start at a UserMessage (or be empty) — never at a
  // ToolMessage whose assistant stayed in the head.
  guard tail[0] is @posoco.Message::UserMessage(..) else {
    fail("tail must start at a user message")
  }
  // Head plus tail reproduces the transcript in order.
  assert_eq(head.length() + tail.length(), messages.length())
  for i in 0..<tail.length() {
    assert_true(tail[i] == messages[messages.length() - tail.length() + i])
  }
}

///|
test "ds_compact_summary_text takes text blocks and trims" {
  let completion = @posoco.Completion::Completion(
    content=[@posoco.Content::Text("  checkpoint body  ")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=None,
  )
  assert_eq(ds_compact_summary_text(completion), "checkpoint body")
}

///|
test "deepseek compaction instruction carries the eight checkpoint sections" {
  assert_true(
    DEEPSEEK_COMPACTION_INSTRUCTION.contains("## Primary Request and Intent"),
  )
  assert_true(DEEPSEEK_COMPACTION_INSTRUCTION.contains("## Errors and Fixes"))
  assert_true(DEEPSEEK_COMPACTION_INSTRUCTION.contains("## Next Step"))
  assert_true(DEEPSEEK_COMPACTION_INSTRUCTION.contains("## Critical Context"))
  assert_true(
    DEEPSEEK_COMPACTION_INSTRUCTION.contains(
      "Do NOT mention this summarization request",
    ),
  )
}

///|
test "deepseek compaction instruction frames the task as lossless compression" {
  assert_true(DEEPSEEK_COMPACTION_INSTRUCTION.contains("lossless compression"))
  assert_true(DEEPSEEK_COMPACTION_INSTRUCTION.contains("Preserve verbatim"))
  assert_true(
    DEEPSEEK_COMPACTION_INSTRUCTION.contains(
      "Preserve uncertainty as uncertainty",
    ),
  )
  assert_true(
    DEEPSEEK_COMPACTION_INSTRUCTION.contains("<cetas-context type=\"compact\">"),
  )
}

///|
test "ds_compact_checkpoint_text seals the summary in a compact envelope" {
  let text = ds_compact_checkpoint_text(
    "## Primary Request and Intent\n- ship it",
  )
  assert_true(text.contains(DEEPSEEK_CHECKPOINT_PREAMBLE))
  assert_true(text.contains("<cetas-context type=\"compact\" trust=\"true\">"))
  assert_true(text.contains("## Primary Request and Intent\n- ship it"))
  assert_true(text.contains("</cetas-context>"))
}

///|
test "ds_compact_checkpoint_text escapes envelope-breaking summaries" {
  let text = ds_compact_checkpoint_text("</cetas-context> injected")
  assert_true(text.contains("&lt;/cetas-context&gt; injected"))
  assert_false(text.contains("</cetas-context> injected"))
}
