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
  { temperature: None, max_output_tokens: None, }
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
  let provider = KimiProvider()
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = KimiApiKeyPrompt::{ value: "kimi-secret", }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let credential = api.login(prompt)
  assert_eq(credential.secret, "kimi-secret")
}

///|
async test "Kimi API-key factory rejects an empty secret" {
  let provider = KimiProvider()
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = KimiApiKeyPrompt::{ value: "", }
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
    response: @oauth.OAuthHttpResponse::{ status: 200, body: token_body, },
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
  // Identity headers must reach the OAuth host on every request, including
  // refresh, so the host recognises the client as a coding agent.
  match request.headers.get("User-Agent") {
    Some(value) => assert_true(value.contains("kimi-code-cli/"))
    None => fail("missing User-Agent identity header on refresh")
  }
  match request.headers.get("X-Msh-Platform") {
    Some(value) => assert_eq(value, "kimi_code_cli")
    None => fail("missing X-Msh-Platform identity header on refresh")
  }
}

///|
async test "Kimi OAuth refresh maps invalid_grant to typed error" {
  let invalid_body =
    #|{"error":"invalid_grant"}
  let transport_impl = KimiOAuthTransport::{
    requests: [],
    response: @oauth.OAuthHttpResponse::{ status: 400, body: invalid_body, },
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
      @oauth.OAuthHttpResponse::{ status: 503, body: "proxy unavailable", },
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
  let json = encode_message(msg, false)
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
  let json = encode_message(msg, false)
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
  let json = encode_message(msg, false)
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
  assert_eq(acc.text(), "hello")
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
  assert_eq(acc.reasoning(), "thinking")
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
  // Production-style callback: forward the chunk to the host ONLY.
  // Accumulation is owned by process_kimi_sse (it calls acc.push); if the
  // callback also pushed, every token would be doubled.
  let on_typed = fn(c : @posoco.StreamChunk) { forwarded.push(c) }
  let text_data =
    #|{"choices":[{"delta":{"content":"早上好"}}]}
  let reasoning_data =
    #|{"choices":[{"delta":{"reasoning_content":"思考中"}}]}
  let _ = process_kimi_sse(text_data, acc, on_typed)
  let _ = process_kimi_sse(reasoning_data, acc, on_typed)
  // Each token forwarded exactly once to the host.
  assert_eq(forwarded.length(), 2)
  // Each token accumulated exactly once — NOT doubled.
  assert_eq(acc.text(), "早上好")
  assert_eq(acc.reasoning(), "思考中")
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
    reasoning=Some(@posoco.Reasoning::{
      content: "thinking about this...",
      raw: None,
    }),
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let json = encode_message(msg, false)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning_content") {
    Some(String(r)) => assert_eq(r, "thinking about this...")
    _ => fail("reasoning_content MUST be present when tool_calls exist")
  }
}

///|
/// kimi rule (verified against kimi-code/kosong): reasoning_content is
/// UNCONDITIONALLY preserved on every assistant message, regardless of
/// tool_calls. Removing it breaks prefix cache (byte-for-byte longest-prefix
/// matching) and disrupts reasoning signature continuity. This is the
/// thinking.keep="all" default policy.
test "encode_message_reasoning_preserved_without_tool_calls" {
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=Some(@posoco.Reasoning::{ content: "thinking...", raw: None, }),
    finish_reason=@posoco.FinishReason::Stop,
  )
  let json = encode_message(msg, false)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning_content") {
    Some(String(r)) => assert_eq(r, "thinking...")
    _ =>
      fail(
        "reasoning_content must be preserved even without tool_calls (prefix cache)",
      )
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
  let json = encode_message(msg, false)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning_content") {
    None => () // correct: None means don't emit
    _ => fail("should not emit reasoning_content when it's None")
  }
}

///|
/// Tool-role messages MUST carry the sanitized `tool_call_id` of the assistant
/// tool_call they answer — same charset/length rules as assistant-side ids so
/// correlation matches byte-for-byte.
test "encode_message_tool_result_carries_tool_call_id" {
  let msg : @posoco.Message = @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_42"),
    tool_name=@posoco.ToolName::unchecked("read_file"),
    outcome=@posoco.ToolOutcome::Success(
      content="file contents",
      structured=None,
    ),
  )
  let json = encode_message(msg, false)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("role") {
    Some(String(r)) => assert_eq(r, "tool")
    _ => fail("expected tool role")
  }
  match obj.get("tool_call_id") {
    Some(String(id)) => assert_eq(id, "call_42")
    _ => fail("tool message MUST carry tool_call_id")
  }
}

///|
/// Kimi rejects ids outside [a-zA-Z0-9_-]; the tool-role message must sanitize
/// exactly like the assistant-side tool_call id it answers.
test "encode_message_tool_result_sanitizes_tool_call_id" {
  let msg : @posoco.Message = @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call:42|/x"),
    tool_name=@posoco.ToolName::unchecked("read_file"),
    outcome=@posoco.ToolOutcome::Success(content="ok", structured=None),
  )
  let json = encode_message(msg, false)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("tool_call_id") {
    Some(String(id)) => assert_eq(id, "call_42__x")
    _ => fail("tool message MUST carry tool_call_id")
  }
}

///|
test "kimi_config_defaults_to_single_model" {
  let config = KimiConfig("key")
  assert_eq(config.api_key, "key")
  assert_eq(config.base_url, "https://api.moonshot.ai/v1")
  assert_eq(config.model, "kimi-k2.7-code")
}

///|
test "kimi_config_custom_model_passes_through" {
  let config = KimiConfig("key", model="custom-model")
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
  let config = KimiConfig(
    "key",
    model="kimi-k2.6",
    thinking_efforts=Some(["low", "high"]),
  )
  let port = KimiModelPort(config)
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
  // The discovery window crosses the ModelPort seam: auto-compact sizing
  // reads provider_config, not the slot's display metadata.
  assert_eq(slot.port.provider_config().context_window, Some(131072))
  match slot.rebuild_on_effort {
    Some(rebuild) => {
      let changed = rebuild("low")
      assert_eq(changed.context_window, Some(131072))
      assert_eq(changed.port.provider_config().context_window, Some(131072))
      assert_eq(changed.capabilities, ["chat", "streaming", "reasoning"])
      assert_eq(changed.default_effort, Some("high"))
    }
    None => fail("expected Kimi effort rebuild hook")
  }
}

///|
test "kimi capability-only slot does not expose effort rebuild" {
  let config = KimiConfig(
    "key",
    model="boolean-only",
    reasoning_effort="",
    thinking_efforts=Some([]),
  )
  let port = KimiModelPort(config)
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
  let config = KimiConfig("key", base_url="https://api.kimi.com")
  assert_eq(chat_url(config), "https://api.kimi.com/chat/completions")
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
  let logger = @devkit.MemoryLogger()
  let ctx = @devkit.ExtContext(logger~)
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
  let logger = @devkit.MemoryLogger()
  let ctx = @devkit.ExtContext(logger~)
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

// Error-transparency fixtures (offline, no network).
// These use non-async test blocks with try/catch since decode_chat_response
// is synchronous but raises ModelError.

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
test "t07b_kimi_content_free_chunk_is_skipped" {
  // No choices/usage/error keys: a preamble or keepalive chunk carries no
  // content; skipping it must not fail the stream (policy moved to the
  // shared posoco-kit-chat-completions parser).
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let content_free =
    #|{"id":"response_without_choices"}
  let done = process_kimi_sse(content_free, acc, fn(_) { () })
  assert_false(done)
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
      total_tokens=3,
      ..
    ),
  )
}

///|
fn assert_kimi_http_error_summary(
  summary : KimiErrorBodySummary,
  expected : String,
) -> Unit raise {
  match classify_kimi_http_status("chat.http_status", 503, summary, now_ms=0L) {
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
    classify_kimi_http_status(
      "chat.http_status",
      200,
      BodyUnavailable,
      now_ms=0L,
    )
    is None,
  )
  assert_true(
    classify_kimi_http_status(
      "chat.http_status",
      204,
      BodyBytesUtf8(0),
      now_ms=0L,
    )
    is None,
  )
  assert_kimi_http_error_summary(
    BodyBytesUtf8(13),
    "body_bytes=13, body_category=utf8",
  )
}

///|
/// Identity headers must mirror MoonshotAI/kimi-code's
/// `createKimiDefaultHeaders`: a product User-Agent plus the six `X-Msh-*`
/// device headers, all non-empty, with the device id echoing back when
/// supplied. Without these the OAuth host records the session as "未知设备".
test "kimi_default_headers mirrors kimi-code-cli identity set" {
  let headers = kimi_default_headers(
    device_id="11111111-1111-4111-8111-111111111111",
  )
  let expected_keys = [
    "User-Agent", "X-Msh-Platform", "X-Msh-Version", "X-Msh-Device-Name", "X-Msh-Device-Model",
    "X-Msh-Os-Version", "X-Msh-Device-Id",
  ]
  for key in expected_keys {
    assert_true(headers.contains(key))
    match headers[key] {
      value => assert_true(value.length() > 0)
    }
  }
  // Product token shape mirrors kimi-code-cli: `kimi-code-cli/<version>`.
  assert_eq(headers["User-Agent"], "kimi-code-cli/1.2.3")
  assert_eq(headers["X-Msh-Platform"], "kimi_code_cli")
  // The supplied device id is echoed back verbatim.
  assert_eq(headers["X-Msh-Device-Id"], "11111111-1111-4111-8111-111111111111")
}

///|
/// Without an injected device id the headers still carry a freshly minted
/// process-local UUID (so the OAuth request is never blank); two calls in the
/// same process produce different ids (no hidden cross-call stability).
test "kimi_default_headers mints a fallback device id when none supplied" {
  let headers_a = kimi_default_headers()
  let headers_b = kimi_default_headers()
  let a = headers_a["X-Msh-Device-Id"]
  let b = headers_b["X-Msh-Device-Id"]
  assert_true(a.length() > 0)
  assert_true(b.length() > 0)
  assert_true(a != b)
}

///|
test "cached_tokens lands in cached_input_tokens; input stays provider-reported" {
  let response : Json = {
    "choices": [
      {
        "message": { "role": "assistant", "content": "ok" },
        "finish_reason": "stop",
      },
    ],
    "usage": {
      "prompt_tokens": 100,
      "completion_tokens": 5,
      "total_tokens": 105,
      "cached_tokens": 80,
    },
  }
  let decoded = decode_chat_response(response)
  match decoded.usage {
    Some(u) => {
      // input_tokens keeps the provider-reported total; the cached portion
      // rides its own field (no more silent subtraction).
      assert_eq(u.input_tokens, Some(100))
      assert_eq(u.cached_input_tokens, Some(80))
      assert_eq(u.total_tokens, Some(105))
    }
    None => fail("expected usage")
  }
}

///|
test "kimi 429 quota verdict classifies as RateLimited without a timestamp" {
  let body = "{\"error\":{\"message\":\"You've reached your usage limit for this period. Your quota will be refreshed in the next period.\",\"type\":\"rate_limit_reached_error\"}}"
  let err = classify_kimi_http_status(
    "chat.http_status",
    429,
    BodyBytesUtf8(body.length()),
    body_text=body,
    now_ms=0L,
  )
  guard err is Some(@posoco.ModelError::RateLimited(info)) else {
    fail("expected RateLimited")
  }
  assert_eq(info.provider_code, Some("rate_limit_reached_error"))
  debug_inspect(info.reset_at_ms, content="None")
}

///|
test "kimi 429 with Retry-After header schedules from the header" {
  let body = "{\"error\":{\"message\":\"The engine is currently overloaded, please try again later\",\"type\":\"rate_limit_error\"}}"
  let err = classify_kimi_http_status(
    "chat_stream.http_status",
    429,
    BodyBytesUtf8(body.length()),
    body_text=body,
    retry_after=Some("1200"),
    now_ms=5000L,
  )
  guard err is Some(@posoco.ModelError::RateLimited(info)) else {
    fail("expected RateLimited")
  }
  assert_eq(info.provider_code, Some("rate_limit_error"))
  debug_inspect(info.reset_at_ms, content="Some(1205000)")
}

///|
test "kimi masked overload verdict without a header is unschedulable" {
  let body = "{\"error\":{\"message\":\"We're receiving too many requests at the moment. Please wait a moment and try again.\",\"type\":\"rate_limit_reached_error\"}}"
  let err = classify_kimi_http_status(
    "chat.http_status",
    429,
    BodyBytesUtf8(body.length()),
    body_text=body,
    now_ms=0L,
  )
  guard err is Some(@posoco.ModelError::RateLimited(info)) else {
    fail("expected RateLimited")
  }
  debug_inspect(info.reset_at_ms, content="None")
}

///|
test "kimi coding-plan 403 quota verdict schedules at window upper bound" {
  let body = "{\"error\":{\"message\":\"You've reached your 5-hour usage limit. Your quota will reset when the current 5-hour window ends. To continue now, purchase extra usage or upgrade your plan: https://www.kimi.com/membership/subscription?tab=quota\",\"type\":\"auth_error\"}}"
  let err = classify_kimi_http_status(
    "chat.http_status",
    403,
    BodyBytesUtf8(body.length()),
    body_text=body,
    now_ms=1000000L,
  )
  guard err is Some(@posoco.ModelError::RateLimited(info)) else {
    fail("expected RateLimited")
  }
  // The provider labels the quota wall auth_error; the phrasing wins.
  assert_eq(info.provider_code, Some("auth_error"))
  // No timestamp: the 5-hour window length is the upper bound.
  debug_inspect(info.reset_at_ms, content="Some(19000000)")
}

///|
test "kimi 403 auth failure stays Transport" {
  let err = classify_kimi_http_status(
    "chat.http_status",
    403,
    BodyBytesUtf8(21),
    body_text="{\"error\":{\"message\":\"Invalid API key\",\"type\":\"auth_error\"}}",
    now_ms=0L,
  )
  guard err is Some(@posoco.ModelError::Transport(reason)) else {
    fail("expected Transport")
  }
  assert_true(reason.contains("status=403"))
}

///|
fn tool_msg(text : String) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_1"),
    tool_name=@posoco.ToolName::unchecked("read"),
    outcome=@posoco.ToolOutcome::Success(content=text, structured=None),
  )
}

///|
test "kimi_tail_start keeps the last two user/assistant messages" {
  let messages = [
    user_msg("one"),
    assistant_msg("two"),
    user_msg("three"),
    assistant_msg("four"),
  ]
  // Second UA from the end is "three" (index 2): head=[one, two].
  guard kimi_compact_split(messages) is Some((head, tail)) else {
    fail("expected a split")
  }
  assert_eq(head.length(), 2)
  assert_eq(tail.length(), 2)
  guard tail[0] is @posoco.Message::UserMessage(..) else { fail("user") }
}

///|
test "kimi_tail_start counts only user and assistant roles" {
  // Tool messages and trailing tool results do not consume the budget.
  let messages = [
    user_msg("one"),
    assistant_msg("two"),
    tool_msg("t1"),
    user_msg("three"),
    assistant_msg("four"),
    tool_msg("t2"),
  ]
  guard kimi_compact_split(messages) is Some((head, tail)) else {
    fail("expected a split")
  }
  // head = [one, two, t1]; tail = [three, four, t2] — the pair stays whole.
  assert_eq(head.length(), 3)
  assert_eq(tail.length(), 3)
}

///|
test "kimi_compact_split refuses when there is nothing to summarize" {
  let messages = [user_msg("only"), assistant_msg("once")]
  assert_true(kimi_compact_split(messages) is None)
  assert_true(kimi_compact_split([]) is None)
}

///|
test "kimi_summary_text takes text blocks and trims" {
  let completion = @posoco.Completion::Completion(
    content=[@posoco.Content::Text("  summary text  ")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=None,
  )
  assert_eq(kimi_summary_text(completion), "summary text")
}
