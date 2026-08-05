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
  assert_eq(acc.text, "hello")
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
    Err(@posoco.ModelError::ResponseParse(message)) => {
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
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("stage=error"))
      assert_false(message.contains("secret-error-body"))
    }
    _ => fail("error event must be a typed terminal failure")
  }
}

///|
test "t07b_llm_completed_event_structure_and_usage_are_strict" {
  let acc = @posoco.StreamAccumulator()
  let missing_output =
    #|{"type":"response.completed","response":{"status":"completed"}}
  let output_result = Ok(process_sse_event(missing_output, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match output_result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stage=completed.output"))
    _ => fail("completed response output is required")
  }
  let missing_total =
    #|{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1}}}
  let usage_result = Ok(process_sse_event(missing_total, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match usage_result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stage=usage.total_tokens"))
    _ => fail("completed response usage must preserve total_tokens")
  }
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
  let missing_field : Json = {
    "output": [],
    "status": "completed",
    "usage": { "input_tokens": 1 },
  }
  assert_openai_response_parse(missing_field, "usage.output_tokens")
  let missing_total : Json = {
    "output": [],
    "status": "completed",
    "usage": { "input_tokens": 1, "output_tokens": 1 },
  }
  assert_openai_response_parse(missing_total, "usage.total_tokens")
  let wrong_total : Json = {
    "output": [],
    "status": "completed",
    "usage": { "input_tokens": 1, "output_tokens": 1, "total_tokens": "secret" },
  }
  assert_openai_response_parse(wrong_total, "usage.total_tokens")
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
  let provider = OpenAIProvider::new(transport=Some(transport))
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
    Json::Object(fields) =>
      assert_eq(
        fields.get("reasoning"),
        Some(@json.parse("{\"effort\":\"high\"}")),
      )
    _ => fail("Responses request body must be an object")
  }
}
