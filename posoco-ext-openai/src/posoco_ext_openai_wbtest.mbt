// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.

///|
/// Build an OpenAI Responses API output item (function_call) with given args.
fn build_function_call_json(
  id : String,
  name : String,
  args_str : String,
) -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("function_call")),
      ("call_id", Json::string(id)),
      ("name", Json::string(name)),
      ("arguments", Json::string(args_str)),
    ]),
  )
}

///|
/// T07-B: malformed tool-call arguments JSON must raise ResponseParse,
/// not silently become {}.
test "t07b_llm_malformed_tool_args_raises" {
  let bad_call = build_function_call_json("tc_1", "bad", "not-valid-json")
  let resp_json = Json::object(
    Map::from_array([
      ("output", Json::array([bad_call])),
      ("status", Json::string("completed")),
    ]),
  )
  let result = Ok(parse_openai_response(resp_json)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(_)) => ()
    _ => fail("expected ResponseParse for malformed tool arguments")
  }
}

///|
/// T07-B: valid tool-call arguments still decode correctly (no false positive).
test "t07b_llm_valid_tool_args_still_decode" {
  let ok_call = build_function_call_json("tc_1", "ok", "{}")
  let resp_json = Json::object(
    Map::from_array([
      ("output", Json::array([ok_call])),
      ("status", Json::string("completed")),
    ]),
  )
  let resp = parse_openai_response(resp_json)
  let tcs = resp.tool_calls()
  assert_eq(tcs.length(), 1)
  assert_eq(tcs[0].name.to_string(), "ok")
}

///|
test "t07b_llm_malformed_sse_is_loud_and_redacted" {
  let acc = @posoco.StreamAccumulator()
  let secret = "secret-sse-payload"
  let result = Ok(process_sse_event(secret, acc, fn(_) { () })) catch {
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
test "t07b_llm_valid_delta_and_completed_events" {
  let acc = @posoco.StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let delta =
    #|{"type":"response.output_text.delta","delta":"hello"}
  let completed =
    #|{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":2,"output_tokens":1,"total_tokens":3}}}
  assert_false(process_sse_event(delta, acc, fn(c) { chunks.push(c) }))
  assert_true(process_sse_event(completed, acc, fn(c) { chunks.push(c) }))
  assert_eq(acc.text(), "hello")
  assert_true(acc.usage_input == Some(2))
  assert_true(acc.usage_output == Some(1))
  assert_true(acc.usage_total == Some(3))
  assert_true(chunks[chunks.length() - 1] is @posoco.StreamChunk::Finish(_))
}

///|
test "t07b_llm_incomplete_and_error_events_are_loud_and_redacted" {
  let acc = @posoco.StreamAccumulator()
  let incomplete =
    #|{"type":"response.incomplete","response":{"status":"incomplete","error":{"message":"secret-incomplete"}}}
  let incomplete_result = Ok(process_sse_event(incomplete, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match incomplete_result {
    Err(@posoco.ModelError::Transport(message)) => {
      assert_true(message.contains("stage=response.incomplete"))
      assert_false(message.contains("secret-incomplete"))
    }
    _ => fail("response.incomplete must be a typed terminal failure")
  }
  let error_event =
    #|{"type":"error","code":"bad","message":"secret-error-body","param":null}
  let error_result = Ok(process_sse_event(error_event, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match error_result {
    Err(@posoco.ModelError::Transport(message)) => {
      assert_true(message.contains("stage=error"))
      assert_false(message.contains("secret-error-body"))
    }
    _ => fail("error event must be a typed terminal failure")
  }
}

///|
/// Missing/null output on completed is tolerated as empty (Stop); missing
/// usage token fields map to None (chat-completions tolerance alignment).
test "t07b_llm_completed_event_tolerates_missing_output_and_usage_fields" {
  let acc = @posoco.StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let missing_output =
    #|{"type":"response.completed","response":{"status":"completed"}}
  assert_true(process_sse_event(missing_output, acc, fn(c) { chunks.push(c) }))
  match chunks[chunks.length() - 1] {
    @posoco.StreamChunk::Finish(reason~) => assert_eq(reason, "Stop")
    _ => fail("expected a Finish chunk for completed without output")
  }
  let missing_total =
    #|{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1}}}
  assert_true(process_sse_event(missing_total, acc, fn(c) { chunks.push(c) }))
  // Missing total_tokens maps to None in Usage, surfaced as 0 in the chunk.
  assert_true(acc.usage_input == Some(1))
  assert_true(acc.usage_total == Some(0))
}

///|
test "t07b_llm_missing_sse_field_is_loud" {
  let acc = @posoco.StreamAccumulator()
  let missing_delta =
    #|{"type":"response.output_text.delta"}
  let result = Ok(process_sse_event(missing_delta, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("stage=delta"))
    _ => fail("expected ResponseParse for missing delta")
  }
}

///|
test "t07b_llm_missing_tool_identity_is_loud" {
  let acc = @posoco.StreamAccumulator()
  let missing_name =
    #|{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1"}}
  let result = Ok(process_sse_event(missing_name, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("stage=tool.name"))
    _ => fail("expected ResponseParse for missing tool name")
  }
}

///|
/// Explicit-null tolerances aligned with the chat-completions shared parser:
/// null delta events are skipped, null call_id falls back to the item id, a
/// bare {"error": ...} data line is a Transport failure, and null output /
/// message content decode as empty.
test "t07b_llm_explicit_null_fields_are_tolerated" {
  let acc = @posoco.StreamAccumulator()
  let null_delta =
    #|{"type":"response.output_text.delta","delta":null}
  assert_false(process_sse_event(null_delta, acc, fn(_) { () }))
  assert_eq(acc.text(), "")
  let null_call_id =
    #|{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":null,"id":"fc_1","name":"read"}}
  let chunks : Array[@posoco.StreamChunk] = []
  assert_false(process_sse_event(null_call_id, acc, fn(c) { chunks.push(c) }))
  match chunks[0] {
    @posoco.StreamChunk::ToolCallDelta(index~, id~, name~, arguments_delta~) => {
      assert_eq(index, 0)
      assert_eq(id, Some("fc_1"))
      assert_eq(name, Some("read"))
      assert_true(arguments_delta is None)
    }
    _ => fail("null call_id must fall back to the item id")
  }
  let bare_error =
    #|{"error":{"message":"secret-stream-error","type":"server_error"}}
  let error_result = Ok(process_sse_event(bare_error, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match error_result {
    Err(@posoco.ModelError::Transport(message)) => {
      assert_true(message.contains("stage=error"))
      assert_false(message.contains("secret-stream-error"))
    }
    _ => fail("a bare error data line must be a Transport failure")
  }
  let null_output : Json = { "output": null, "status": "completed" }
  assert_true(
    parse_openai_response(null_output).finish_reason()
    is @posoco.FinishReason::Stop,
  )
  let null_content : Json = {
    "output": [{ "type": "message", "content": null }],
    "status": "completed",
  }
  assert_eq(parse_openai_response(null_content).message.content.length(), 0)
}

///|
test "t07b_llm_stream_termination_is_protocol_driven" {
  assert_true(classify_stream_termination(ExplicitTerminal) is None)
  match classify_stream_termination(CleanEof) {
    Some(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("terminal_marker=missing"))
    _ => fail("clean EOF before terminal marker must be ResponseParse")
  }
  match classify_stream_termination(TransportFailure) {
    Some(@posoco.ModelError::Transport(msg)) =>
      assert_true(msg.contains("stage=read_stream"))
    _ => fail("read failure must be Transport")
  }
}

///|
test "t07b_llm_tool_argument_error_does_not_echo_payload" {
  let secret = "secret-tool-arguments"
  let bad_call = build_function_call_json("tc_1", "bad", secret)
  let resp_json = Json::object(
    Map::from_array([
      ("output", Json::array([bad_call])),
      ("status", Json::string("completed")),
    ]),
  )
  let result = Ok(parse_openai_response(resp_json)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) => {
      assert_true(msg.contains("payload_chars="))
      assert_false(msg.contains(secret))
    }
    _ => fail("expected redacted ResponseParse")
  }
}

///|
test "t07b_llm_stream_tool_argument_error_is_redacted" {
  let acc = @posoco.StreamAccumulator()
  let secret = "secret-stream-tool-arguments"
  acc.push(
    @posoco.StreamChunk::ToolCallDelta(
      index=0,
      id=Some("call_1"),
      name=Some("bad"),
      arguments_delta=Some(secret),
    ),
  )
  let result = Ok(validate_stream_tool_calls(acc)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) => {
      assert_true(msg.contains("payload_chars="))
      assert_false(msg.contains(secret))
    }
    _ => fail("expected redacted stream argument error")
  }
}

///|
test "t07b_llm_valid_stream_tool_call_completes" {
  let acc = @posoco.StreamAccumulator()
  let added =
    #|{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"read"}}
  let arguments =
    #|{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{}"}
  let completed =
    #|{"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","call_id":"call_1","name":"read","arguments":"{}"}]}}
  assert_false(process_sse_event(added, acc, fn(_) { () }))
  assert_false(process_sse_event(arguments, acc, fn(_) { () }))
  assert_true(process_sse_event(completed, acc, fn(_) { () }))
  validate_stream_tool_calls(acc)
  let completion = acc.to_completion()
  let tcs = completion.tool_calls()
  assert_eq(tcs.length(), 1)
  assert_eq(tcs[0].call_id.to_string(), "call_1")
  assert_eq(tcs[0].name.to_string(), "read")
}

///|
fn assert_openai_response_parse(resp : Json, stage : String) -> Unit raise {
  let result = Ok(parse_openai_response(resp)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stage=" + stage))
    _ => fail("expected OpenAI ResponseParse at " + stage)
  }
}

///|
test "t07b_llm_nonstream_output_item_shape_is_strict" {
  assert_openai_response_parse(
    { "output": [7], "status": "completed" },
    "output_item",
  )
}

///|
test "t07b_llm_nonstream_message_content_is_strict" {
  let response : Json = {
    "output": [{ "type": "message", "content": "not-an-array" }],
    "status": "completed",
  }
  assert_openai_response_parse(response, "message.content")
}

///|
test "t07b_llm_nonstream_output_text_is_strict" {
  let response : Json = {
    "output": [
      { "type": "message", "content": [{ "type": "output_text", "text": 7 }] },
    ],
    "status": "completed",
  }
  assert_openai_response_parse(response, "message.output_text.text")
}

///|
test "t07b_llm_nonstream_status_is_required_and_typed" {
  assert_openai_response_parse({ "output": [] }, "status")
  assert_openai_response_parse({ "output": [], "status": 7 }, "status")
  assert_openai_response_parse(
    { "output": [], "status": "incomplete" },
    "status",
  )
  let secret = "secret-provider-error"
  let provider_error : Json = {
    "output": [],
    "status": "failed",
    "error": { "message": "secret-provider-error" },
  }
  let result = Ok(parse_openai_response(provider_error)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("stage=error"))
      assert_false(message.contains(secret))
    }
    _ => fail("provider error response must be loud")
  }
}

///|
test "t07b_llm_nonstream_usage_is_strict" {
  let wrong_type : Json = {
    "output": [],
    "status": "completed",
    "usage": { "input_tokens": "secret", "output_tokens": 1 },
  }
  assert_openai_response_parse(wrong_type, "usage.input_tokens")
  let wrong_total : Json = {
    "output": [],
    "status": "completed",
    "usage": { "input_tokens": 1, "output_tokens": 1, "total_tokens": "secret" },
  }
  assert_openai_response_parse(wrong_total, "usage.total_tokens")
  // Missing usage token fields map to None instead of failing.
  let missing_fields : Json = {
    "output": [],
    "status": "completed",
    "usage": { "input_tokens": 1 },
  }
  let decoded = parse_openai_response(missing_fields)
  match decoded.usage {
    Some(usage) => {
      assert_true(usage.input_tokens == Some(1))
      assert_true(usage.output_tokens is None)
      assert_true(usage.total_tokens is None)
    }
    None => fail("expected decoded usage")
  }
  // "usage": null is treated as absent.
  let null_usage : Json = { "output": [], "status": "completed", "usage": null }
  assert_true(parse_openai_response(null_usage).usage is None)
}

///|
test "t07b_llm_valid_nonstream_response_still_decodes" {
  let response : Json = {
    "output": [
      {
        "type": "message",
        "content": [{ "type": "output_text", "text": "hello" }],
      },
    ],
    "status": "completed",
    "usage": { "input_tokens": 2, "output_tokens": 1, "total_tokens": 7 },
  }
  let decoded = parse_openai_response(response)
  assert_true(decoded.finish_reason() is @posoco.FinishReason::Stop)
  match decoded.message.content {
    [@posoco.Content::Text("hello")] => ()
    _ => fail("expected decoded output text")
  }
  match decoded.usage {
    Some(usage) => {
      assert_true(usage.input_tokens == Some(2))
      assert_true(usage.output_tokens == Some(1))
      assert_true(usage.total_tokens == Some(7))
    }
    None => fail("expected decoded usage")
  }
}

///|
test "t07b_llm_http_error_formatter_is_payload_free" {
  let message = format_openai_http_error(
    "http_status",
    429,
    classify_openai_error_body(19, Some(19)),
  )
  assert_eq(
    message, "OpenAI HTTP error (stage=http_status, status=429, body_chars=19, body_category=utf8)",
  )
  assert_false(message.contains("secret-response-body"))
  let invalid_utf8 = format_openai_http_error(
    "http_status",
    502,
    classify_openai_error_body(23, None),
  )
  assert_eq(
    invalid_utf8, "OpenAI HTTP error (stage=http_status, status=502, body_bytes=23, body_category=invalid_utf8)",
  )
  let read_failed = format_openai_http_error("http_status", 503, BodyReadFailed)
  assert_true(read_failed.contains("status=503"))
  assert_true(read_failed.contains("body_category=read_failed"))
  assert_true(
    classify_openai_http_status("http_status", 200, BodyBytesUtf8(0)) is None,
  )
  assert_true(
    classify_openai_http_status("http_status", 204, BodyBytesUtf8(0)) is None,
  )
  match
    classify_openai_http_status("http_status", 429, BodyBytesInvalidUtf8(7)) {
    Some(@posoco.ModelError::Transport(error)) => {
      assert_true(error.contains("status=429"))
      assert_true(error.contains("body_category=invalid_utf8"))
    }
    _ => fail("4xx status must remain a typed HTTP transport error")
  }
}

///|
test "codex_oauth_poll_accepts_only_explicit_pending_states" {
  match parse_codex_poll_body("{\"error\":\"authorization_pending\"}") {
    CodexPollResponse::Pending => ()
    _ => fail("authorization_pending must remain pending")
  }
  match parse_codex_poll_body("{\"error\":\"slow_down\"}") {
    CodexPollResponse::SlowDown => ()
    _ => fail("slow_down must remain a slow-down response")
  }
  match
    parse_codex_poll_body(
      "{\"authorization_code\":\"code\",\"code_verifier\":\"verifier\"}",
    ) {
    CodexPollResponse::Ready(code, verifier) => {
      assert_eq(code, "code")
      assert_eq(verifier, "verifier")
    }
    _ => fail("complete poll response must be ready")
  }
}

///|
test "codex_oauth_poll_rejects_malformed_or_unknown_responses" {
  let malformed = Ok(parse_codex_poll_body("{not-json")) catch { e => Err(e) }
  match malformed {
    Err(@oauth.OAuthError::ParseError(message)) =>
      assert_true(message.contains("not valid JSON"))
    _ => fail("malformed poll JSON must raise ParseError")
  }
  let missing = Ok(parse_codex_poll_body("{}")) catch { e => Err(e) }
  match missing {
    Err(@oauth.OAuthError::ParseError(message)) =>
      assert_true(message.contains("authorization_code"))
    _ => fail("missing credentials must raise ParseError")
  }
  let unknown = Ok(parse_codex_poll_body("{\"error\":\"unexpected\"}")) catch {
    e => Err(e)
  }
  match unknown {
    Err(@oauth.OAuthError::ParseError(message)) =>
      assert_true(message.contains("unknown error"))
    _ => fail("unknown poll error must raise ParseError")
  }
  let denied = Ok(parse_codex_poll_body("{\"error\":\"access_denied\"}")) catch {
    e => Err(e)
  }
  match denied {
    Err(@oauth.OAuthError::AccessDenied) => ()
    _ => fail("access_denied must raise AccessDenied")
  }
}

///|
/// Regression for the production failure:
/// `Codex OAuth poll response error must be a string`. OpenAI's device-token
/// endpoint also returns the RFC-style error as an object with a `code` field.
test "codex_oauth_poll_accepts_object_pending_error" {
  let result = Ok(
    parse_codex_poll_body(
      "{\"error\":{\"code\":\"deviceauth_authorization_pending\"}}",
    ),
  ) catch {
    err => Err(err)
  }
  match result {
    Ok(CodexPollResponse::Pending) => ()
    _ => fail("object deviceauth_authorization_pending must remain pending")
  }
}

///|
test "codex_oauth_poll_matches_pi_status_and_payload_semantics" {
  match parse_codex_poll_response(403, "not-json") {
    CodexPollResponse::Pending => ()
    _ => fail("HTTP 403 must remain pending even with a non-JSON body")
  }
  match parse_codex_poll_response(404, "{}") {
    CodexPollResponse::Pending => ()
    _ => fail("HTTP 404 must remain pending")
  }
  match
    parse_codex_poll_response(
      200, "{\"error\":{\"code\":\"deviceauth_authorization_pending\"}}",
    ) {
    CodexPollResponse::Pending => ()
    _ => fail("object pending error must remain pending")
  }
  match parse_codex_poll_response(200, "{\"error\":\"slow_down\"}") {
    CodexPollResponse::SlowDown => ()
    _ => fail("slow_down must remain a slow-down response")
  }
  match
    parse_codex_poll_response(
      200, "{\"authorization_code\":\"code\",\"code_verifier\":\"verifier\"}",
    ) {
    CodexPollResponse::Ready(code, verifier) => {
      assert_eq(code, "code")
      assert_eq(verifier, "verifier")
    }
    _ => fail("successful poll response must be ready")
  }
  match parse_codex_interval_ms(Json::string("2.5")) {
    Some(value) => assert_eq(value, 2500)
    None => fail("numeric interval string must be accepted")
  }
  match parse_codex_interval_ms(Json::number(2.5)) {
    Some(value) => assert_eq(value, 2500)
    None => fail("numeric interval must be accepted")
  }
}

///|
test "codex requests include the JWT account header" {
  let credential = @oauth.Credential::Credential(
    access_token=codex_test_access_token(),
    refresh_token="refresh",
    expires_at=3600,
    metadata=Map([("account_id", "acct-123")]),
  )
  let config = OpenAIConfig::from_codex_credential(credential, "gpt-5")
  let headers = build_headers(config)
  assert_eq(headers.get("chatgpt-account-id"), Some("acct-123"))
}

///|
fn codex_test_access_token() -> String {
  // JWT payload: {"https://api.openai.com/auth.chatgpt_account_id":"acct-123"}
  "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGguY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0xMjMifQ.sig"
}

///|
test "codex token parser requires JWT account metadata and strict expiry" {
  let response = @json.parse(
    "{\"access_token\":\"" +
    codex_test_access_token() +
    "\",\"refresh_token\":\"refresh\",\"expires_in\":3600}",
  )
  let credential = parse_token_response(response)
  assert_eq(credential.metadata.get("account_id"), Some("acct-123"))
  let fractional = @json.parse(
    "{\"access_token\":\"" +
    codex_test_access_token() +
    "\",\"refresh_token\":\"refresh\",\"expires_in\":3600.5}",
  )
  let result = Ok(parse_token_response(fractional)) catch { err => Err(err) }
  match result {
    Err(@oauth.OAuthError::ParseError(detail)) =>
      assert_true(detail.contains("finite positive integer"))
    _ => fail("fractional expires_in must be rejected")
  }
}

///|
struct CodexRecordingTransport {
  requests : Array[@oauth.OAuthHttpRequest]
  responses : Array[@oauth.OAuthHttpResponse]
}

///|
pub impl @oauth.OAuthHttpTransport for CodexRecordingTransport with fn post(
  self : CodexRecordingTransport,
  request : @oauth.OAuthHttpRequest,
) -> @oauth.OAuthHttpResponse {
  self.requests.push(request)
  self.responses[self.requests.length() - 1]
}

///|
async test "codex oauth fake transport covers device poll and exchange wire" {
  let transport_impl = CodexRecordingTransport::{
    requests: [],
    responses: [
      @oauth.OAuthHttpResponse::{
        status: 200,
        body: "{\"device_auth_id\":\"device-id\",\"user_code\":\"ABCD\",\"interval\":0}",
      },
      @oauth.OAuthHttpResponse::{
        status: 200,
        body: "{\"authorization_code\":\"auth-code\",\"code_verifier\":\"verifier\"}",
      },
      @oauth.OAuthHttpResponse::{
        status: 200,
        body: "{\"access_token\":\"" +
        codex_test_access_token() +
        "\",\"refresh_token\":\"refresh-next\",\"expires_in\":3600}",
      },
    ],
  }
  let transport : &@oauth.OAuthHttpTransport = transport_impl
  let oauth = CodexOAuth::CodexOAuth(transport=Some(transport))
  let interaction_impl = @oauth.NoopAuthInteraction::NoopAuthInteraction()
  let interaction : &@oauth.AuthInteraction = interaction_impl
  let credential = oauth.login(interaction)
  assert_eq(credential.metadata.get("account_id"), Some("acct-123"))
  assert_eq(transport_impl.requests.length(), 3)
  assert_eq(
    transport_impl.requests[0].url,
    "https://auth.openai.com/api/accounts/deviceauth/usercode",
  )
  assert_true(transport_impl.requests[0].body.contains("client_id"))
  assert_eq(
    transport_impl.requests[1].url,
    "https://auth.openai.com/api/accounts/deviceauth/token",
  )
  assert_eq(
    transport_impl.requests[2].body,
    "grant_type=authorization_code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code=auth-code&code_verifier=verifier&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback",
  )
}

///|
test "openai and codex model parsers keep separate envelopes" {
  let api = parse_openai_models(
    @json.parse(
      "{\"object\":\"list\",\"data\":[{\"id\":\"gpt-api\"},{\"id\":\"gpt-api-2\",\"display_name\":\"API Two\"}]}",
    ),
  )
  assert_eq(api[0].id, "gpt-api")
  assert_eq(api[0].display_name, "gpt-api")
  assert_eq(api[1].display_name, "API Two")
  let codex = parse_codex_models(
    @json.parse(
      "{\"models\":[{" +
      "\"slug\":\"gpt-codex\",\"display_name\":\"GPT Codex\",\"description\":\"coding\"," +
      "\"default_reasoning_level\":\"high\",\"supported_reasoning_levels\":[" +
      "{\"effort\":\"low\",\"description\":\"fast\"}," +
      "{\"effort\":\"high\",\"description\":\"deep\"}]," +
      "\"visibility\":\"list\",\"supported_in_api\":true,\"priority\":1,\"context_window\":272000" +
      "}]}",
    ),
  )
  assert_eq(codex[0].slug, "gpt-codex")
  assert_eq(
    codex[0].supported_reasoning_levels.map(fn(level) { level.effort }),
    ["low", "high"],
  )
  assert_eq(codex[0].default_reasoning_level, Some("high"))
  assert_eq(codex[0].context_window, Some(272000))
}

///|
test "openai models parser rejects a non-list envelope" {
  let result = Ok(
    parse_openai_models(@json.parse("{\"object\":\"not-list\",\"data\":[]}")),
  ) catch {
    err => Err(err)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("object must be list"))
    _ => fail("expected typed OpenAI envelope failure")
  }
}

///|
struct OpenAIModelsRecordingTransport {
  urls : Array[String]
  headers : Array[Map[String, String]]
  responses : Array[OpenAIModelsHttpResponse]
}

///|
pub impl OpenAIModelsHttpTransport for OpenAIModelsRecordingTransport with fn get(
  self : OpenAIModelsRecordingTransport,
  url : String,
  headers : Map[String, String],
) -> OpenAIModelsHttpResponse {
  self.urls.push(url)
  self.headers.push(headers)
  self.responses[self.urls.length() - 1]
}

///|
async test "codex refresh sends version and account headers and preserves efforts" {
  let transport_impl = OpenAIModelsRecordingTransport::{
    urls: [],
    headers: [],
    responses: [
      OpenAIModelsHttpResponse::{
        status: 200,
        body: "{\"models\":[{" +
        "\"slug\":\"gpt-codex\",\"display_name\":\"GPT Codex\"," +
        "\"default_reasoning_level\":\"medium\",\"supported_reasoning_levels\":[" +
        "{\"effort\":\"low\",\"description\":\"fast\"}," +
        "{\"effort\":\"medium\",\"description\":\"balanced\"}," +
        "{\"effort\":\"xhigh\",\"description\":\"deep\"}]," +
        "\"visibility\":\"list\",\"supported_in_api\":true,\"priority\":1," +
        "\"context_window\":272000}]}",
      },
    ],
  }
  let transport : &OpenAIModelsHttpTransport = transport_impl
  let provider = OpenAIProvider(transport=Some(transport))
  let credential = @oauth.Credential::Credential(
    access_token=codex_test_access_token(),
    refresh_token="refresh",
    expires_at=0,
    metadata=Map([("account_id", "acct-123")]),
  )
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      @json.parse("{\"model\":\"gpt-codex\",\"reasoning_effort\":\"xhigh\"}"),
    ),
    provider_credential=Some(@oauth.ProviderCredential::OAuth(credential)),
  )
  let result = provider.refresh(source)
  match result {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slots = catalog.slots()
      assert_eq(slots.length(), 1)
      assert_eq(slots[0].thinking_efforts, ["low", "medium", "xhigh"])
      assert_eq(slots[0].default_effort, Some("medium"))
      match slots[0].rebuild_on_effort {
        Some(rebuild) => {
          let changed = rebuild("low")
          assert_eq(changed.thinking_efforts, ["low", "medium", "xhigh"])
        }
        None => fail("Codex reasoning levels must expose effort rebuild")
      }
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("OAuth source was configured")
  }
  assert_eq(
    transport_impl.urls[0],
    "https://chatgpt.com/backend-api/codex/models?client_version=0.146.0",
  )
  assert_eq(
    transport_impl.headers[0].get("Authorization"),
    Some("Bearer " + codex_test_access_token()),
  )
  assert_eq(
    transport_impl.headers[0].get("chatgpt-account-id"),
    Some("acct-123"),
  )
}

///|
test "openai reasoning effort is carried in responses request body" {
  let body = build_request_body(
    [],
    [],
    { temperature: None, max_output_tokens: None },
    "gpt-codex",
    Some("high"),
  )
  match body {
    Json::Object(fields) => {
      // Codex parity: stateless (store:false), effort + summary:auto, and
      // the encrypted reasoning payload requested via include.
      assert_eq(fields.get("store"), Some(Json::boolean(false)))
      assert_eq(
        fields.get("reasoning"),
        Some(@json.parse("{\"effort\":\"high\",\"summary\":\"auto\"}")),
      )
      assert_eq(
        fields.get("include"),
        Some(@json.parse("[\"reasoning.encrypted_content\"]")),
      )
    }
    _ => fail("Responses request body must be an object")
  }
}

///|
/// Manual state management (migrate-to-responses guide): an assistant message
/// with tool calls expands into a message item PLUS one function_call item
/// per call — dropping function_call items is a named common migration error.
test "openai_input_assistant_tool_calls_emit_function_call_items" {
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("let me check")],
    tool_calls=[
      {
        call_id: @posoco.CallId::unchecked("call_1"),
        name: @posoco.ToolName::unchecked("read"),
        arguments: Json::object({ "path": Json::string("/tmp/x") }),
      },
    ],
    reasoning=None,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let items = posoco_message_to_openai_items(msg)
  assert_eq(items.length(), 2)
  guard items[0] is Object(m0) else { fail("expected message item") }
  match m0.get("role") {
    Some(String("assistant")) => ()
    _ => fail("expected assistant message item")
  }
  guard items[1] is Object(fc) else { fail("expected function_call item") }
  match fc.get("type") {
    Some(String("function_call")) => ()
    _ => fail("expected function_call type")
  }
  match fc.get("call_id") {
    Some(String(id)) => assert_eq(id, "call_1")
    _ => fail("expected call_id")
  }
  match fc.get("name") {
    Some(String(n)) => assert_eq(n, "read")
    _ => fail("expected name")
  }
  match fc.get("arguments") {
    Some(String(a)) => assert_true(a.contains("/tmp/x"))
    _ => fail("expected arguments string")
  }
}

///|
/// Reasoning items replay verbatim ahead of the assistant message item
/// (official reasoning guide: pass back all reasoning items untouched).
test "openai_input_replays_reasoning_items_verbatim" {
  let raw_item = Json::object(
    Map::from_array([
      ("id", Json::string("rs_123")),
      ("type", Json::string("reasoning")),
      ("summary", Json::array([])),
      ("encrypted_content", Json::string("enc_payload")),
    ]),
  )
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=Some(@posoco.Reasoning::{
      content: "",
      raw: Some(Json::array([raw_item])),
    }),
    finish_reason=@posoco.FinishReason::Stop,
  )
  let items = posoco_message_to_openai_items(msg)
  assert_eq(items.length(), 2)
  assert_true(items[0] == raw_item)
  guard items[1] is Object(m1) else { fail("expected message item") }
  match m1.get("role") {
    Some(String("assistant")) => ()
    _ => fail("expected assistant message item after reasoning")
  }
}

///|
/// Responses with a reasoning item surface it on the Completion: summary text
/// as user-visible content, the raw item preserved for replay.
test "openai_parse_captures_reasoning_items" {
  let reasoning_item = Json::object(
    Map::from_array([
      ("id", Json::string("rs_9")),
      ("type", Json::string("reasoning")),
      (
        "summary",
        Json::array([
          Json::object(
            Map::from_array([
              ("type", Json::string("summary_text")),
              ("text", Json::string("thought hard")),
            ]),
          ),
        ]),
      ),
    ]),
  )
  let message_item = Json::object(
    Map::from_array([
      ("type", Json::string("message")),
      ("role", Json::string("assistant")),
      (
        "content",
        Json::array([
          Json::object(
            Map::from_array([
              ("type", Json::string("output_text")),
              ("text", Json::string("hi")),
            ]),
          ),
        ]),
      ),
    ]),
  )
  let resp_json = Json::object(
    Map::from_array([
      ("output", Json::array([reasoning_item, message_item])),
      ("status", Json::string("completed")),
    ]),
  )
  let resp = parse_openai_response(resp_json)
  match resp.message.reasoning {
    Some(r) => {
      assert_eq(r.content, "thought hard")
      assert_true(r.raw == Some(Json::array([reasoning_item])))
    }
    None => fail("reasoning item must be captured")
  }
}

///|
/// Streaming: reasoning items on the terminal response.completed event are
/// captured into the sink and attached to the accumulated completion.
test "openai_stream_captures_reasoning_items_from_completed" {
  let acc = @posoco.StreamAccumulator()
  let sink = ReasoningSink::{ items: [], summary: "" }
  let completed =
    #|{"type":"response.completed","response":{"status":"completed","output":[{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"s"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}]}}
  assert_true(
    process_sse_event(completed, acc, fn(_) { () }, reasoning_sink=sink),
  )
  let completion = attach_reasoning_items(acc.to_completion(), sink)
  match completion.message.reasoning {
    Some(r) => {
      assert_eq(r.content, "s")
      match r.raw {
        Some(Json::Array(items)) => assert_eq(items.length(), 1)
        _ => fail("raw reasoning items must be attached")
      }
    }
    None => fail("reasoning must be attached from the completed event")
  }
}

///|
/// /responses/compact output decodes into canonical messages: the opaque
/// compaction item rides the next assistant's Reasoning.raw, reasoning items
/// are preserved, function_call/output pairs become tool calls and tool
/// messages, wire order intact.
test "openai_compact_decodes_window" {
  let window =
    #|{"output":[
    #|  {"type":"compaction","id":"cmp_1","encrypted_content":"zzz"},
    #|  {"role":"user","content":[{"type":"input_text","text":"q1"}]},
    #|  {"type":"reasoning","id":"rs_1","summary":[]},
    #|  {"role":"assistant","content":[{"type":"output_text","text":"a1"}]},
    #|  {"type":"function_call","call_id":"call_1","name":"get_weather","arguments":"{}"},
    #|  {"type":"function_call_output","call_id":"call_1","output":"sunny"}
    #|]}
  let messages = parse_compact_response(@json.parse(window))
  assert_eq(messages.length(), 5)
  // The leading compaction item flushes as a synthetic empty assistant ahead
  // of the user message, preserving wire order.
  match messages[0] {
    @posoco.Message::AssistantMessage(content~, reasoning~, ..) => {
      assert_eq(content.length(), 0)
      match reasoning {
        Some(r) =>
          match r.raw {
            Some(Json::Array(items)) => {
              assert_eq(items.length(), 1)
              match items[0] {
                Json::Object(m) =>
                  match m.get("type") {
                    Some(Json::String("compaction")) => ()
                    _ => fail("expected compaction item in Reasoning.raw")
                  }
                _ => fail("expected compaction object")
              }
            }
            _ => fail("compaction item must ride Reasoning.raw")
          }
        None => fail("synthetic assistant must carry compaction state")
      }
    }
    _ => fail("expected synthetic assistant for leading compaction item")
  }
  match messages[1] {
    @posoco.Message::UserMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(t) => assert_eq(t, "q1")
        _ => fail("expected user text")
      }
    _ => fail("expected user message")
  }
  match messages[2] {
    @posoco.Message::AssistantMessage(content~, reasoning~, tool_calls~, ..) => {
      assert_eq(tool_calls.length(), 0)
      match content[0] {
        @posoco.Content::Text(t) => assert_eq(t, "a1")
        _ => fail("expected assistant text")
      }
      match reasoning {
        Some(r) =>
          match r.raw {
            Some(Json::Array(items)) => assert_eq(items.length(), 1)
            _ => fail("reasoning item must ride Reasoning.raw")
          }
        None => fail("assistant must carry reasoning state")
      }
    }
    _ => fail("expected assistant message")
  }
  match messages[3] {
    @posoco.Message::AssistantMessage(tool_calls~, finish_reason~, ..) => {
      assert_eq(tool_calls.length(), 1)
      assert_eq(tool_calls[0].call_id.to_string(), "call_1")
      assert_eq(tool_calls[0].name.to_string(), "get_weather")
      match finish_reason {
        @posoco.FinishReason::ToolCalls => ()
        _ => fail("expected ToolCalls finish reason")
      }
    }
    _ => fail("expected synthetic assistant carrying the function_call")
  }
  match messages[4] {
    @posoco.Message::ToolMessage(call_id~, outcome~, ..) => {
      assert_eq(call_id.to_string(), "call_1")
      match outcome {
        @posoco.ToolOutcome::Success(content~, ..) =>
          assert_eq(content, "sunny")
        _ => fail("expected tool success outcome")
      }
    }
    _ => fail("expected tool message")
  }
}

///|
/// Decode → re-encode replays the window as-is: opaque items (compaction,
/// reasoning) come back verbatim and the remaining items keep their order and
/// canonical shape (assistant text normalizes to input_text).
test "openai_compact_roundtrip_replays_verbatim" {
  let window =
    #|{"output":[
    #|  {"type":"compaction","id":"cmp_1","encrypted_content":"zzz"},
    #|  {"role":"user","content":[{"type":"input_text","text":"q1"}]},
    #|  {"type":"reasoning","id":"rs_1","summary":[]},
    #|  {"role":"assistant","content":[{"type":"output_text","text":"a1"}]},
    #|  {"type":"function_call","call_id":"call_1","name":"get_weather","arguments":"{}"},
    #|  {"type":"function_call_output","call_id":"call_1","output":"sunny"}
    #|]}
  let messages = parse_compact_response(@json.parse(window))
  let re_encoded : Array[Json] = []
  for m in messages {
    for item in posoco_message_to_openai_items(m) {
      re_encoded.push(item)
    }
  }
  let expected_window =
    #|[{"type":"compaction","id":"cmp_1","encrypted_content":"zzz"},
    #| {"role":"user","content":[{"type":"input_text","text":"q1"}]},
    #| {"type":"reasoning","id":"rs_1","summary":[]},
    #| {"role":"assistant","content":[{"type":"input_text","text":"a1"}]},
    #| {"type":"function_call","call_id":"call_1","name":"get_weather","arguments":"{}"},
    #| {"type":"function_call_output","call_id":"call_1","output":"sunny"}]
  let expected = @json.parse(expected_window)
  assert_true(Json::array(re_encoded) == expected)
}

///|
/// The compact request body is exactly {model, input} — fully stateless.
test "openai_compact_request_body_shape" {
  let body = build_compact_request_body(
    [@posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")])],
    "gpt-5",
  )
  guard body is Json::Object(m) else { fail("expected object body") }
  assert_true(m.contains("model"))
  assert_true(m.contains("input"))
  assert_eq(m.length(), 2)
  match m.get("model") {
    Some(Json::String("gpt-5")) => ()
    _ => fail("model field mismatch")
  }
  match m.get("input") {
    Some(Json::Array(items)) => assert_eq(items.length(), 1)
    _ => fail("input must be an item array")
  }
}

///|
/// Compact envelope failures are loud: a provider error object and a
/// non-array output both raise ResponseParse.
test "openai_compact_parse_rejects_bad_envelopes" {
  let provider_error_json =
    #|{"error":{"type":"server_error","message":"boom"}}
  let provider_error = @json.parse(provider_error_json)
  let result = Ok(parse_compact_response(provider_error)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("stage=error"))
    _ => fail("expected ResponseParse for provider error envelope")
  }
  let bad_output_json =
    #|{"output":{}}
  let bad_output = @json.parse(bad_output_json)
  let result2 = Ok(parse_compact_response(bad_output)) catch { e => Err(e) }
  match result2 {
    Err(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("stage=output"))
    _ => fail("expected ResponseParse for non-array output")
  }
}

///|
test "responses usage carries cached input tokens" {
  let resp : Json = {
    "usage": {
      "input_tokens": 1200,
      "output_tokens": 50,
      "total_tokens": 1250,
      "input_tokens_details": { "cached_tokens": 1000 },
    },
  }
  match extract_usage(resp) {
    Some(u) => {
      assert_eq(u.input_tokens, Some(1200))
      assert_eq(u.cached_input_tokens, Some(1000))
    }
    None => fail("expected usage")
  }
  // Absent details read as None; a wrong type stays loud.
  let no_details : Json = {
    "usage": { "input_tokens": 10, "output_tokens": 5, "total_tokens": 15 },
  }
  match extract_usage(no_details) {
    Some(u) => assert_true(u.cached_input_tokens is None)
    None => fail("expected usage")
  }
  let bad_details : Json = {
    "usage": {
      "input_tokens": 10,
      "output_tokens": 5,
      "total_tokens": 15,
      "input_tokens_details": { "cached_tokens": "many" },
    },
  }
  let outcome : Result[@posoco.Usage?, Error] = Ok(extract_usage(bad_details)) catch {
    error => Err(error)
  }
  assert_true(outcome is Err(_))
}

///|
test "codex discovery slot reports context_window through provider_config" {
  let config = OpenAIConfig::with_base_url(
    "sk-test", "gpt-5.2", "https://example.com/v1",
  )
  let port = OpenAIModelPort(config)
  let info = CodexModelInfo::{
    slug: "gpt-5.2-codex",
    display_name: "GPT-5.2 Codex",
    description: None,
    default_reasoning_level: Some("medium"),
    supported_reasoning_levels: [
      CodexReasoningLevel::{ effort: "medium", description: "balanced" },
    ],
    visibility: "list",
    supported_in_api: true,
    priority: 0,
    context_window: Some(400000),
  }
  let slot = port.model_catalog_from_codex_models([info]).slots()[0]
  assert_eq(slot.model_id, "gpt-5.2-codex")
  assert_eq(slot.context_window, Some(400000))
  // The discovery window crosses the ModelPort seam so the Agent sizes
  // auto-compact from the active model's own capacity.
  assert_eq(slot.port.provider_config().context_window, Some(400000))
}
