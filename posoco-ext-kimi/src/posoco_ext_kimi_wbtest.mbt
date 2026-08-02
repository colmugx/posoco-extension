///|
/// Blackbox tests for posoco-ext-kimi wire encoding/decoding.
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
  { temperature: None, max_output_tokens: None }
}

///|
/// Provider-neutral prompt fake used to exercise Kimi's API-key seam.
struct KimiApiKeyPrompt {
  value : String
}

///|
struct KimiOAuthTransport {
  requests : Array[@oauth.OAuthHttpRequest]
  response : @oauth.OAuthHttpResponse
}

///|
pub impl @oauth.OAuthHttpTransport for KimiOAuthTransport with fn post(
  self : KimiOAuthTransport,
  request : @oauth.OAuthHttpRequest,
) -> @oauth.OAuthHttpResponse {
  self.requests.push(request)
  self.response
}

///|
pub impl @oauth.AuthPromptInteraction for KimiApiKeyPrompt with fn prompt(
  self : KimiApiKeyPrompt,
  _request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  self.value
}

///|
async test "Kimi API-key factory validates and returns an opaque credential" {
  let provider = KimiProvider::new()
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = KimiApiKeyPrompt::{ value: "kimi-secret" }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let credential = api.login(prompt)
  assert_eq(credential.secret, "kimi-secret")
}

///|
async test "Kimi API-key factory rejects an empty secret" {
  let provider = KimiProvider::new()
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = KimiApiKeyPrompt::{ value: "" }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let result = Ok(api.login(prompt)) catch { error => Err(error) }
  match result {
    Err(@oauth.OAuthError::ParseError(message)) =>
      assert_true(message.contains("must not be empty"))
    _ => fail("expected empty Kimi API key to fail")
  }
}

///|
async test "Kimi OAuth refresh matches form wire and preserves token fields" {
  let token_body =
    #|{"access_token":"access","refresh_token":"refresh-next","expires_in":3600,"token_type":"Bearer"}
  let transport_impl = KimiOAuthTransport::{
    requests: [],
    response: @oauth.OAuthHttpResponse::{ status: 200, body: token_body },
  }
  let transport : &@oauth.OAuthHttpTransport = transport_impl
  let oauth_impl = KimiOAuth::KimiOAuth(transport=Some(transport))
  let oauth : &@oauth.OAuthProvider = oauth_impl
  let credential = @oauth.Credential::Credential(
    access_token="old-access",
    refresh_token="refresh/token",
    expires_at=1,
  )
  let refreshed = oauth.refresh(credential)
  assert_eq(refreshed.access_token, "access")
  assert_eq(refreshed.refresh_token, "refresh-next")
  assert_eq(transport_impl.requests.length(), 1)
  let request = transport_impl.requests[0]
  assert_eq(
    request.body,
    "client_id=17e5f671-d194-4dfb-9706-5516cb48c098&grant_type=refresh_token&refresh_token=refresh%2Ftoken",
  )
  match request.headers.get("Content-Type") {
    Some(value) => assert_eq(value, "application/x-www-form-urlencoded")
    None => fail("missing content type")
  }
  match request.headers.get("Accept") {
    Some(value) => assert_eq(value, "application/json")
    None => fail("missing accept header")
  }
}

///|
async test "Kimi OAuth refresh maps invalid_grant to typed error" {
  let invalid_body =
    #|{"error":"invalid_grant"}
  let transport_impl = KimiOAuthTransport::{
    requests: [],
    response: @oauth.OAuthHttpResponse::{ status: 400, body: invalid_body },
  }
  let transport : &@oauth.OAuthHttpTransport = transport_impl
  let oauth_impl = KimiOAuth::KimiOAuth(transport=Some(transport))
  let oauth : &@oauth.OAuthProvider = oauth_impl
  let credential = @oauth.Credential::Credential(
    access_token="old-access",
    refresh_token="old-refresh",
    expires_at=1,
  )
  let result = Ok(oauth.refresh(credential)) catch { error => Err(error) }
  match result {
    Err(@oauth.OAuthError::InvalidGrant) => ()
    _ => fail("expected typed invalid_grant error")
  }
}

///|
struct KimiRetryOAuthTransport {
  requests : Array[@oauth.OAuthHttpRequest]
  responses : Array[@oauth.OAuthHttpResponse]
}

///|
pub impl @oauth.OAuthHttpTransport for KimiRetryOAuthTransport with fn post(
  self : KimiRetryOAuthTransport,
  request : @oauth.OAuthHttpRequest,
) -> @oauth.OAuthHttpResponse {
  self.requests.push(request)
  self.responses[self.requests.length() - 1]
}

///|
async test "Kimi OAuth refresh retries transient 5xx once then succeeds" {
  let transport_impl = KimiRetryOAuthTransport::{
    requests: [],
    responses: [
      @oauth.OAuthHttpResponse::{ status: 503, body: "proxy unavailable" },
      @oauth.OAuthHttpResponse::{
        status: 200,
        body: "{\"access_token\":\"access\",\"refresh_token\":\"refresh-next\",\"expires_in\":3600}",
      },
    ],
  }
  let transport : &@oauth.OAuthHttpTransport = transport_impl
  let oauth_impl = KimiOAuth::KimiOAuth(transport=Some(transport))
  let oauth : &@oauth.OAuthProvider = oauth_impl
  let credential = @oauth.Credential::Credential(
    access_token="old-access",
    refresh_token="old-refresh",
    expires_at=1,
  )
  let refreshed = oauth.refresh(credential)
  assert_eq(refreshed.access_token, "access")
  assert_eq(transport_impl.requests.length(), 2)
}

///|
async test "Kimi OAuth refresh rejects fractional expiry" {
  let transport_impl = KimiOAuthTransport::{
    requests: [],
    response: @oauth.OAuthHttpResponse::{
      status: 200,
      body: "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":3600.5}",
    },
  }
  let transport : &@oauth.OAuthHttpTransport = transport_impl
  let oauth_impl = KimiOAuth::KimiOAuth(transport=Some(transport))
  let oauth : &@oauth.OAuthProvider = oauth_impl
  let credential = @oauth.Credential::Credential(
    access_token="old-access",
    refresh_token="old-refresh",
    expires_at=1,
  )
  let result = Ok(oauth.refresh(credential)) catch { error => Err(error) }
  match result {
    Err(@oauth.OAuthError::ParseError(detail)) =>
      assert_true(detail.contains("invalid expires_in"))
    _ => fail("fractional expiry must be rejected")
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
  // reasoning_content must NOT be present (kimi optimization)
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
  // Minimal valid kimi response
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
  // Verify finish reason (method, not field)
  assert_true(resp.finish_reason() is @posoco.FinishReason::Stop)
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
  match resp.message.reasoning {
    None => ()
    _ => fail("basic chat should have no reasoning")
  }
}

///|
test "decode_chat_response_with_reasoning" {
  // kimi-reasoner response includes reasoning_content
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
/// SSE parser tests — process_kimi_sse is pure (no network).

///|
test "sse_text_delta" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let data = "{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}"
  let done = process_kimi_sse(data, acc, fn(c) { chunks.push(c) })
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
  let _ = process_kimi_sse(data, acc, fn(c) { chunks.push(c) })
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
  let done = process_kimi_sse("[DONE]", acc, fn(c) { chunks.push(c) })
  assert_true(done)
  assert_true(chunks[0] is @posoco.StreamChunk::Finish(_))
}

///|
test "sse_finish_with_usage" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let data =
    #|{"choices":[{"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
  let done = process_kimi_sse(data, acc, fn(c) { chunks.push(c) })
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
  let _ = process_kimi_sse(data1, acc, fn(c) { chunks.push(c) })
  // Second chunk: arguments delta
  let data2 =
    #|{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":\"/x\"}"}}]}}]}
  let _ = process_kimi_sse(data2, acc, fn(c) { chunks.push(c) })
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
/// process_kimi_sse with a production-style callback (one that forwards
/// to a host AND accumulates), each delta must land in the accumulator
/// exactly once. The bridge in kimi.mbt previously called acc.push inside
/// on_typed while process_kimi_sse also pushed, doubling every text and
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
  // owned by process_kimi_sse; the callback must not also push.
  let on_typed = fn(c : @posoco.StreamChunk) {
    acc.push(c)
    forwarded.push(c)
  }
  let text_data =
    #|{"choices":[{"delta":{"content":"早上好"}}]}
  let reasoning_data =
    #|{"choices":[{"delta":{"reasoning_content":"思考中"}}]}
  let _ = process_kimi_sse(text_data, acc, on_typed)
  let _ = process_kimi_sse(reasoning_data, acc, on_typed)
  // Each token forwarded exactly once to the host.
  assert_eq(forwarded.length(), 2)
  // Each token accumulated exactly once — NOT doubled.
  assert_eq(acc.text, "早上好")
  assert_eq(acc.reasoning, "思考中")
}

///|
/// kimi rule: assistant with tool_calls MUST resend reasoning_content.
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
    reasoning=Some(@posoco.Reasoning::{ content: "thinking about this..." }),
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
/// kimi rule: assistant WITHOUT tool_calls — reasoning_content is omitted
/// even if present (saves tokens, preserves prefix cache).
test "encode_message_reasoning_omitted_without_tool_calls" {
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=Some(@posoco.Reasoning::{ content: "thinking..." }),
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
/// kimi rule: tool_calls present but reasoning is None — encoder
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
test "kimi_config_defaults_to_single_model" {
  let config = KimiConfig::new("key")
  assert_eq(config.api_key, "key")
  assert_eq(config.base_url, "https://api.moonshot.ai/v1")
  assert_eq(config.model, "kimi-v4-flash")
}

///|
test "kimi_config_custom_model_passes_through" {
  let config = KimiConfig::new("key", model="custom-model")
  assert_eq(config.model, "custom-model")
}

///|
test "kimi_models_parser_prefers_nested_effort_declaration" {
  let payload : Json = {
    "data": [
      {
        "id": "kimi-v4-flash",
        "context_length": 32768,
        "supports_thinking_type": "both",
        "supports_reasoning": true,
        // Legacy fields are intentionally contradictory; nested metadata is
        // the provider-owned source of truth when both forms are present.
        "support_efforts": ["bogus"],
        "default_effort": "bogus",
        "think_efforts": {
          "support": true,
          "valid_efforts": ["low", "high"],
          "default_effort": "high",
        },
      },
    ],
  }
  let models = parse_kimi_models(payload)
  assert_eq(models.length(), 1)
  assert_eq(models[0].thinking_efforts, ["low", "high"])
  assert_eq(models[0].default_effort, Some("high"))
}

///|
test "kimi_models_parser_reads_legacy_flat_efforts_without_guessing" {
  let payload : Json = {
    "data": [
      {
        "id": "legacy-kimi",
        "context_length": 16384,
        "support_efforts": ["fast", "deep"],
        "default_effort": "deep",
        "supports_reasoning": true,
      },
    ],
  }
  let models = parse_kimi_models(payload)
  assert_eq(models[0].thinking_efforts, ["fast", "deep"])
  assert_eq(models[0].default_effort, Some("deep"))
  assert_true(models[0].capabilities.contains("reasoning"))
}

///|
test "kimi_models_parser_keeps_reasoning_capability_without_fabricated_efforts" {
  let payload : Json = {
    "data": [
      {
        "id": "boolean-only",
        "context_length": 8192,
        "supports_reasoning": true,
      },
    ],
  }
  let models = parse_kimi_models(payload)
  assert_true(models[0].thinking_efforts.is_empty())
  assert_eq(models[0].default_effort, None)
  assert_true(models[0].capabilities.contains("reasoning"))
}

///|
test "kimi_models_parser_rejects_flat_default_without_declared_efforts" {
  let payload : Json = {
    "data": [
      { "id": "invalid-flat", "context_length": 8192, "default_effort": "high" },
    ],
  }
  let result : Result[Array[KimiModelInfo], @posoco.ModelError] = Ok(
    parse_kimi_models(payload),
  ) catch {
    err => Err(err)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("requires support_efforts"))
    _ => fail("expected invalid flat effort declaration")
  }
}

///|
test "kimi_dynamic_slot_rebuild_preserves_catalog_metadata" {
  let config = KimiConfig::new(
    "key",
    model="kimi-k2.6",
    thinking_efforts=Some(["low", "high"]),
  )
  let port = KimiModelPort::new(config)
  let info = KimiModelInfo::{
    id: "kimi-k2.6",
    display_name: "Kimi K2.6",
    context_window: 131072,
    thinking_efforts: ["low", "high"],
    default_effort: Some("high"),
    capabilities: ["chat", "streaming", "reasoning"],
  }
  let other = KimiModelInfo::{
    id: "kimi-k2.5",
    display_name: "Kimi K2.5",
    context_window: 65536,
    thinking_efforts: ["high"],
    default_effort: Some("high"),
    capabilities: ["chat", "streaming", "reasoning"],
  }
  let catalog = port.model_catalog_from_models([other, info])
  let slot = catalog.slots()[0]
  assert_eq(slot.model_id, "kimi-k2.6")
  assert_eq(slot.context_window, Some(131072))
  assert_eq(slot.capabilities, ["chat", "streaming", "reasoning"])
  match slot.rebuild_on_effort {
    Some(rebuild) => {
      let changed = rebuild("low")
      assert_eq(changed.context_window, Some(131072))
      assert_eq(changed.capabilities, ["chat", "streaming", "reasoning"])
      assert_eq(changed.default_effort, Some("high"))
    }
    None => fail("expected Kimi effort rebuild hook")
  }
}

///|
test "kimi capability-only slot does not expose effort rebuild" {
  let config = KimiConfig::new(
    "key",
    model="boolean-only",
    reasoning_effort="",
    thinking_efforts=Some([]),
  )
  let port = KimiModelPort::new(config)
  let info = KimiModelInfo::{
    id: "boolean-only",
    display_name: "Boolean-only Kimi",
    context_window: 8192,
    thinking_efforts: [],
    default_effort: None,
    capabilities: ["chat", "streaming", "reasoning"],
  }
  let slot = port.model_catalog_from_models([info]).slots()[0]
  assert_true(slot.thinking_efforts.is_empty())
  match slot.rebuild_on_effort {
    None => ()
    Some(_) => fail("capability-only Kimi slot must not expose effort rebuild")
  }
}

///|
test "endpoint_helper_builds_chat_url" {
  let config = KimiConfig::new("key", base_url="https://api.kimi.com")
  assert_eq(chat_url(config), "https://api.kimi.com/chat/completions")
}

///|
/// build_chat_request takes thinking_json + effort_str directly now; the
/// high-effort path passes them through without warning.
test "build_chat_request_high_thinking_no_warn" {
  let logger = @devkit.MemoryLogger::new()
  let ctx = @devkit.ExtContext::new(logger~)
  let body = build_chat_request(
    ctx,
    [user_msg("hi")],
    [],
    chat_options(),
    "kimi-v4-flash",
    false,
    enabled_thinking_json(Some("high")),
    None,
  )
  guard body is Object(root) else { fail("expected object") }
  assert_json_field_string(root, "model", "kimi-v4-flash")
  guard root.get("thinking") is Some(Object(thinking)) else {
    fail("expected thinking object")
  }
  assert_json_field_string(thinking, "type", "enabled")
  assert_json_field_string(thinking, "effort", "high")
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
    chat_options(),
    "kimi-v4-flash",
    false,
    enabled_thinking_json(Some("max")),
    None,
  )
  guard body is Object(root) else { fail("expected object") }
  guard root.get("thinking") is Some(Object(thinking)) else {
    fail("expected thinking object")
  }
  assert_json_field_string(thinking, "type", "enabled")
  assert_json_field_string(thinking, "effort", "max")
  assert_eq(logger.events.length(), 0)
}

///|
test "build_chat_request_off_disables_thinking_no_warn" {
  let logger = @devkit.MemoryLogger::new()
  let ctx = @devkit.ExtContext::new(logger~)
  let body = build_chat_request(
    ctx,
    [user_msg("hi")],
    [],
    chat_options(),
    "kimi-v4-flash",
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

// ---------------------------------------------------------------------------
// Note: build_chat_request_named_tool_choice, build_chat_request_medium_falls_back_with_warn,
// and build_chat_request_low_and_minimal_fallback were removed.
// ToolChoice and ReasoningEffort are deleted from the public API; the
// thinking-config + reasoning-effort fallback routing that those tests
// exercised now lives inside the modelport (see default_thinking_config in
// kimi.mbt), and build_chat_request's effort_str is a plain String? that
// passes through verbatim with no fallback warnings.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Error-transparency fixtures (offline, no network).
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
/// Malformed tool-call arguments JSON must raise ResponseParse,
/// not silently become {}.
test "t07b_kimi_malformed_tool_args_raises" {
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
test "t07b_kimi_valid_tool_args_still_decode" {
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
test "t07b_kimi_malformed_sse_is_loud_and_redacted" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let secret = "secret-sse-payload"
  let result = Ok(process_kimi_sse(secret, acc, fn(_) { () })) catch {
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
test "t07b_kimi_missing_sse_structure_is_loud" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let missing_choices =
    #|{"id":"response_without_choices"}
  let result = Ok(process_kimi_sse(missing_choices, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("stage=choices"))
    _ => fail("expected ResponseParse for missing choices")
  }
}

///|
test "t07b_kimi_wrong_type_tool_field_is_loud" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let bad_name =
    #|{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":7,"arguments":"{}"}}]}}]}
  let result = Ok(process_kimi_sse(bad_name, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("stage=tool.name"))
    _ => fail("expected ResponseParse for wrong-type tool name")
  }
}

///|
test "t07b_kimi_stream_termination_is_protocol_driven" {
  assert_true(classify_kimi_stream_termination(ExplicitTerminal) is None)
  match classify_kimi_stream_termination(CleanEof) {
    Some(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("terminal_marker=missing"))
    _ => fail("clean EOF before terminal marker must be ResponseParse")
  }
  match classify_kimi_stream_termination(TransportFailure) {
    Some(@posoco.ModelError::Transport(msg)) =>
      assert_true(msg.contains("stage=read_stream"))
    _ => fail("read failure must be Transport")
  }
}

///|
test "t07b_kimi_tool_argument_error_does_not_echo_payload" {
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
test "t07b_kimi_missing_nonstream_tool_arguments_is_loud" {
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
test "t07b_kimi_stream_tool_argument_error_is_redacted" {
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
  let result = Ok(validate_kimi_stream_tool_calls(acc)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) => {
      assert_true(msg.contains("payload_chars="))
      assert_false(msg.contains(secret))
    }
    _ => fail("expected redacted stream argument error")
  }
}

///|
fn assert_kimi_response_parse(resp : Json, stage : String) -> Unit raise {
  let result = Ok(decode_chat_response(resp)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stage=" + stage))
    _ => fail("expected kimi ResponseParse at " + stage)
  }
}

///|
test "t07b_kimi_nonobject_response_is_response_parse" {
  assert_kimi_response_parse(Json::array([]), "response")
}

///|
fn assert_kimi_response_parse_category(
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
    _ => fail("expected kimi ResponseParse at " + stage)
  }
}

///|
test "t07b_kimi_chat_response_shapes_are_structured_and_redacted" {
  assert_kimi_response_parse_category(
    Json::empty_object(),
    "choices",
    "missing",
  )
  assert_kimi_response_parse_category(
    Json::object({ "choices": Json::string("secret-provider-body") }),
    "choices",
    "wrong_type",
  )
  assert_kimi_response_parse_category(
    Json::object({ "choices": Json::array([]) }),
    "choices",
    "empty",
  )
  assert_kimi_response_parse_category(
    Json::object({ "choices": Json::array([Json::string("invalid")]) }),
    "choice",
    "not_object",
  )
  assert_kimi_response_parse_category(
    Json::object({ "choices": Json::array([Json::empty_object()]) }),
    "message",
    "missing",
  )
}

///|
test "t07b_kimi_reasoning_content_is_strict" {
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
  assert_kimi_response_parse(response, "message.reasoning_content")
}

///|
test "t07b_kimi_finish_reason_is_required_and_typed" {
  let missing : Json = {
    "choices": [{ "message": { "role": "assistant", "content": "ok" } }],
  }
  assert_kimi_response_parse(missing, "finish_reason")
  let wrong_type : Json = {
    "choices": [
      {
        "message": { "role": "assistant", "content": "ok" },
        "finish_reason": 7,
      },
    ],
  }
  assert_kimi_response_parse(wrong_type, "finish_reason")
}

///|
test "t07b_kimi_nonstream_usage_is_strict" {
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
  assert_kimi_response_parse(wrong_type, "usage.prompt_tokens")
  let missing_field : Json = {
    "choices": [
      {
        "message": { "role": "assistant", "content": "ok" },
        "finish_reason": "stop",
      },
    ],
    "usage": { "prompt_tokens": 1, "completion_tokens": 1 },
  }
  assert_kimi_response_parse(missing_field, "usage.total_tokens")
}

///|
test "t07b_kimi_valid_nonstream_response_still_decodes" {
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
    decoded.message.reasoning == Some(@posoco.Reasoning::{ content: "checked" }),
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
test "t07b_kimi_http_error_formatter_is_payload_free" {
  let message = format_kimi_http_error(
    "chat.http_status",
    429,
    BodyBytesUtf8(19),
  )
  assert_eq(
    message, "kimi HTTP error (stage=chat.http_status, status=429, body_bytes=19, body_category=utf8)",
  )
  assert_false(message.contains("secret-response-body"))
}

///|
fn assert_kimi_sse_response_parse(
  data : String,
  stage : String,
  category : String,
) -> Unit raise {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let result = Ok(process_kimi_sse(data, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("stage=" + stage))
      assert_true(message.contains("category=" + category))
    }
    _ => fail("expected kimi SSE ResponseParse at " + stage)
  }
}

///|
test "t07b_kimi_stream_usage_fields_are_required" {
  assert_kimi_sse_response_parse(
    "{\"usage\":{\"completion_tokens\":2,\"total_tokens\":3}}", "usage.prompt_tokens",
    "missing",
  )
  assert_kimi_sse_response_parse(
    "{\"usage\":{\"prompt_tokens\":1,\"total_tokens\":3}}", "usage.completion_tokens",
    "missing",
  )
  assert_kimi_sse_response_parse(
    "{\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2}}", "usage.total_tokens",
    "missing",
  )
}

///|
test "t07b_kimi_stream_usage_fields_are_typed" {
  assert_kimi_sse_response_parse(
    "{\"usage\":{\"prompt_tokens\":\"secret\",\"completion_tokens\":2,\"total_tokens\":3}}",
    "usage.prompt_tokens", "wrong_type",
  )
  assert_kimi_sse_response_parse(
    "{\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":false,\"total_tokens\":3}}",
    "usage.completion_tokens", "wrong_type",
  )
  assert_kimi_sse_response_parse(
    "{\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":null}}",
    "usage.total_tokens", "wrong_type",
  )
}

///|
test "t07b_kimi_valid_stream_usage_still_decodes" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let done = process_kimi_sse(
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
      total_tokens=3
    ),
  )
}

///|
fn assert_kimi_http_error_summary(
  summary : KimiErrorBodySummary,
  expected : String,
) -> Unit raise {
  match classify_kimi_http_status("chat.http_status", 503, summary) {
    Some(@posoco.ModelError::Transport(message)) => {
      assert_true(message.contains("status=503"))
      assert_true(message.contains(expected))
      assert_false(message.contains("secret-provider-body"))
    }
    _ => fail("non-2xx response must be Transport")
  }
}

///|
test "t07b_kimi_http_status_classifier_preserves_status_and_redacts_body" {
  assert_true(
    classify_kimi_http_status("chat.http_status", 200, BodyBytesInvalidUtf8(11))
    is None,
  )
  assert_true(
    classify_kimi_http_status("chat.http_status", 204, BodyBytesUtf8(0)) is None,
  )
  assert_kimi_http_error_summary(
    BodyBytesUtf8(13),
    "body_bytes=13, body_category=utf8",
  )
  assert_kimi_http_error_summary(
    BodyBytesInvalidUtf8(11),
    "body_bytes=11, body_category=invalid_utf8",
  )
  assert_kimi_http_error_summary(BodyReadFailed, "body_category=read_failed")
}
