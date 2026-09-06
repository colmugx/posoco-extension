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
/// Malformed tool-call arguments JSON must raise ResponseParse,
/// not silently become {}.
test "t07b_llm_malformed_tool_args_raises" {
  let bad_call = build_function_call_json("tc_1", "bad", "not-valid-json")
  let resp_json = Json::object(
    Map::from_array([
      ("output", Json::array([bad_call])),
      ("status", Json::string("completed")),
    ]),
  )
  let result = Ok(
    @responses.parse_responses_response(provider="OpenAI", resp_json),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(_)) => ()
    _ => fail("expected ResponseParse for malformed tool arguments")
  }
}

///|
/// Valid tool-call arguments still decode correctly (no false positive).
test "t07b_llm_valid_tool_args_still_decode" {
  let ok_call = build_function_call_json("tc_1", "ok", "{}")
  let resp_json = Json::object(
    Map::from_array([
      ("output", Json::array([ok_call])),
      ("status", Json::string("completed")),
    ]),
  )
  let resp = @responses.parse_responses_response(provider="OpenAI", resp_json)
  let tcs = resp.tool_calls()
  assert_eq(tcs.length(), 1)
  assert_eq(tcs[0].name.to_string(), "ok")
}

///|
test "t07b_llm_malformed_sse_is_loud_and_redacted" {
  let acc = @posoco.StreamAccumulator()
  let secret = "secret-sse-payload"
  let result = Ok(
    @responses.process_responses_sse(provider="OpenAI", secret, acc, fn(_) {
      ()
    }),
  ) catch {
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
  assert_false(
    @responses.process_responses_sse(provider="OpenAI", delta, acc, fn(c) {
      chunks.push(c)
    }),
  )
  assert_true(
    @responses.process_responses_sse(provider="OpenAI", completed, acc, fn(c) {
      chunks.push(c)
    }),
  )
  assert_eq(chunks.length(), 3) // one text delta, usage, and terminal finish
  assert_eq(acc.text(), "hello")
  let completion = acc.to_completion()
  match completion.usage {
    Some(usage) => {
      assert_true(usage.input_tokens == Some(2))
      assert_true(usage.output_tokens == Some(1))
      assert_true(usage.total_tokens == Some(3))
    }
    None => fail("expected usage in completion")
  }
  assert_true(chunks[chunks.length() - 1] is @posoco.StreamChunk::Finish(_))
}

///|
test "t07b_llm_incomplete_and_error_events_are_loud_and_redacted" {
  let acc = @posoco.StreamAccumulator()
  let incomplete =
    #|{"type":"response.incomplete","response":{"status":"incomplete","error":{"message":"secret-incomplete"}}}
  let incomplete_result = Ok(
    @responses.process_responses_sse(provider="OpenAI", incomplete, acc, fn(_) {
      ()
    }),
  ) catch {
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
  let error_result = Ok(
    @responses.process_responses_sse(provider="OpenAI", error_event, acc, fn(
      _,
    ) {
      ()
    }),
  ) catch {
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
  assert_true(
    @responses.process_responses_sse(provider="OpenAI", missing_output, acc, fn(
      c,
    ) {
      chunks.push(c)
    }),
  )
  match chunks[chunks.length() - 1] {
    // Wire spelling: the accumulator parses "stop" back into FinishReason::Stop.
    @posoco.StreamChunk::Finish(reason~) => assert_eq(reason, "stop")
    _ => fail("expected a Finish chunk for completed without output")
  }
  let missing_total =
    #|{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1}}}
  assert_true(
    @responses.process_responses_sse(provider="OpenAI", missing_total, acc, fn(
      c,
    ) {
      chunks.push(c)
    }),
  )
  // Missing total_tokens maps to None in Usage, surfaced as 0 in the chunk.
  let completion = acc.to_completion()
  match completion.usage {
    Some(usage) => {
      assert_true(usage.input_tokens == Some(1))
      assert_true(usage.total_tokens == Some(0))
    }
    None => fail("expected usage in completion")
  }
}

///|
test "t07b_llm_missing_sse_field_is_loud" {
  let acc = @posoco.StreamAccumulator()
  let missing_delta =
    #|{"type":"response.output_text.delta"}
  let result = Ok(
    @responses.process_responses_sse(provider="OpenAI", missing_delta, acc, fn(
      _,
    ) {
      ()
    }),
  ) catch {
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
  let result = Ok(
    @responses.process_responses_sse(provider="OpenAI", missing_name, acc, fn(
      _,
    ) {
      ()
    }),
  ) catch {
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
  assert_false(
    @responses.process_responses_sse(provider="OpenAI", null_delta, acc, fn(_) {
      ()
    }),
  )
  assert_eq(acc.text(), "")
  let null_call_id =
    #|{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":null,"id":"fc_1","name":"read"}}
  let chunks : Array[@posoco.StreamChunk] = []
  assert_false(
    @responses.process_responses_sse(provider="OpenAI", null_call_id, acc, fn(
      c,
    ) {
      chunks.push(c)
    }),
  )
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
  let error_result = Ok(
    @responses.process_responses_sse(provider="OpenAI", bare_error, acc, fn(_) {
      ()
    }),
  ) catch {
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
    @responses.parse_responses_response(provider="OpenAI", null_output).finish_reason()
    is @posoco.FinishReason::Stop,
  )
  let null_content : Json = {
    "output": [{ "type": "message", "content": null }],
    "status": "completed",
  }
  assert_eq(
    @responses.parse_responses_response(provider="OpenAI", null_content).message.content.length(),
    0,
  )
}

///|
test "t07b_llm_stream_termination_is_protocol_driven" {
  assert_true(
    @responses.classify_stream_termination(
      provider="OpenAI",
      @responses.StreamTermination::ExplicitTerminal,
    )
    is None,
  )
  match
    @responses.classify_stream_termination(
      provider="OpenAI",
      @responses.StreamTermination::CleanEof,
    ) {
    Some(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("terminal_marker=missing"))
    _ => fail("clean EOF before terminal marker must be ResponseParse")
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
  let result = Ok(
    @responses.parse_responses_response(provider="OpenAI", resp_json),
  ) catch {
    e => Err(e)
  }
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
  let result = Ok(@responses.validate_stream_tool_calls(provider="OpenAI", acc)) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) => {
      assert_true(msg.contains("OpenAI SSE parse failure (stage=tool_calls)"))
      assert_true(msg.contains("malformed tool-call arguments JSON"))
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
  assert_false(
    @responses.process_responses_sse(provider="OpenAI", added, acc, fn(_) { () }),
  )
  assert_false(
    @responses.process_responses_sse(provider="OpenAI", arguments, acc, fn(_) {
      ()
    }),
  )
  assert_true(
    @responses.process_responses_sse(provider="OpenAI", completed, acc, fn(_) {
      ()
    }),
  )
  @responses.validate_stream_tool_calls(provider="OpenAI", acc)
  let completion = acc.to_completion()
  let tcs = completion.tool_calls()
  assert_eq(tcs.length(), 1)
  assert_eq(tcs[0].call_id.to_string(), "call_1")
  assert_eq(tcs[0].name.to_string(), "read")
}

///|
fn assert_openai_response_parse(resp : Json, stage : String) -> Unit raise {
  let result = Ok(@responses.parse_responses_response(provider="OpenAI", resp)) catch {
    e => Err(e)
  }
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
  let result = Ok(
    @responses.parse_responses_response(provider="OpenAI", provider_error),
  ) catch {
    e => Err(e)
  }
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
  let decoded = @responses.parse_responses_response(
    provider="OpenAI",
    missing_fields,
  )
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
  assert_true(
    @responses.parse_responses_response(provider="OpenAI", null_usage).usage
    is None,
  )
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
  let decoded = @responses.parse_responses_response(provider="OpenAI", response)
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
test "codex requests include the JWT account header" {
  let credential = @oauth.Credential::Credential(
    access_token=codex_test_access_token(),
    refresh_token="refresh",
    expires_at=3600,
    metadata=Map([("account_id", "acct-123")]),
  )
  let config = OpenAIConfig::from_codex_credential(credential, "gpt-5")
  let headers = build_headers(config, None, false, false)
  assert_eq(headers.get("chatgpt-account-id"), Some("acct-123"))
}

///|
fn codex_test_access_token() -> String {
  // JWT payload: {"https://api.openai.com/auth":{"chatgpt_account_id":"acct-123"}}
  "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0xMjMifX0.sig"
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
  // Real OpenAI tokens nest the claim under "https://api.openai.com/auth"; a
  // flat dotted key (or a missing claim) must be rejected, not silently read.
  let flat_key_token = "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGguY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0xMjMifQ.sig"
  let flat_key_response = @json.parse(
    "{\"access_token\":\"" +
    flat_key_token +
    "\",\"refresh_token\":\"refresh\",\"expires_in\":3600}",
  )
  let flat_result = Ok(parse_token_response(flat_key_response)) catch {
    err => Err(err)
  }
  match flat_result {
    Err(@oauth.OAuthError::ParseError(detail)) =>
      assert_true(detail.contains("missing chatgpt account id claim"))
    _ => fail("flat-key claim must be rejected; real tokens nest it")
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
/// AuthInteraction fake that captures the authorize URL the flow notifies.
struct CodexRecordingInteraction {
  mut last_auth_url : String
}

///|
pub impl @oauth.AuthInteraction for CodexRecordingInteraction with fn notify(
  self : CodexRecordingInteraction,
  message : @oauth.AuthMessage,
) -> Unit {
  match message {
    @oauth.AuthMessage::AuthUrl(url) => self.last_auth_url = url
    _ => ()
  }
}

///|
pub impl @oauth.AuthInteraction for CodexRecordingInteraction with fn is_cancelled(
  _self : CodexRecordingInteraction,
) -> Bool {
  false
}

///|
/// CallbackServer fake: echoes the state param of the captured authorize URL
/// back to the flow (state is generated inside the flow). `forged_state`
/// returns a mismatched state instead.
struct CodexFakeCallbackServer {
  interaction : CodexRecordingInteraction
  delivered_code : String
  forged_state : Bool
  started_ports : Array[Int]
  mut stop_count : Int
}

///|
pub impl @oauth.CallbackServer for CodexFakeCallbackServer with fn start(
  self : CodexFakeCallbackServer,
  port : Int,
) -> Unit raise @oauth.OAuthError {
  self.started_ports.push(port)
}

///|
pub impl @oauth.CallbackServer for CodexFakeCallbackServer with fn wait_callback(
  self : CodexFakeCallbackServer,
) -> (String, String) raise @oauth.OAuthError {
  let state = match
    codex_extract_query_param(self.interaction.last_auth_url, "state") {
    Some(state) => state
    None => ""
  }
  if self.forged_state {
    (self.delivered_code, "forged-" + state)
  } else {
    (self.delivered_code, state)
  }
}

///|
pub impl @oauth.CallbackServer for CodexFakeCallbackServer with fn stop(
  self : CodexFakeCallbackServer,
) -> Unit {
  self.stop_count += 1
}

///|
/// Extract one key's value from a query string or form-encoded body.
fn codex_extract_query_param(input : String, key : String) -> String? {
  let prefix = key + "="
  let start = if input.has_prefix(prefix) {
    prefix.length()
  } else {
    match input.find("&" + prefix) {
      Some(pos) => pos + 1 + prefix.length()
      None => return None
    }
  }
  let rest = input.sub(start~).to_owned()
  match rest.find("&") {
    Some(amp) => Some(rest.sub(end=amp).to_owned())
    None => Some(rest)
  }
}

///|
fn codex_browser_token_response() -> String {
  "{\"access_token\":\"" +
  codex_test_access_token() +
  "\",\"refresh_token\":\"refresh-next\",\"expires_in\":3600}"
}

///|
async test "codex login drives the pkce browser flow wire" {
  let interaction_impl = CodexRecordingInteraction::{ last_auth_url: "", }
  let server_impl = CodexFakeCallbackServer::{
    interaction: interaction_impl,
    delivered_code: "the_code",
    forged_state: false,
    started_ports: [],
    stop_count: 0,
  }
  let transport_impl = CodexRecordingTransport::{
    requests: [],
    responses: [
      @oauth.OAuthHttpResponse::{
        status: 200,
        body: codex_browser_token_response(),
      },
    ],
  }
  let interaction : &@oauth.AuthInteraction = interaction_impl
  let server : &@oauth.CallbackServer = server_impl
  let transport : &@oauth.OAuthHttpTransport = transport_impl
  let oauth = CodexOAuth::CodexOAuth(transport=Some(transport))
  let credential = oauth.run_browser_login(interaction, server)
  // The authorize URL carries the Codex params, PKCE, scope, and state.
  let auth_url = interaction_impl.last_auth_url
  assert_true(auth_url.has_prefix("https://auth.openai.com/oauth/authorize?"))
  assert_true(auth_url.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
  assert_true(auth_url.contains("originator=posoco"))
  assert_true(auth_url.contains("id_token_add_organizations=true"))
  assert_true(auth_url.contains("codex_cli_simplified_flow=true"))
  assert_true(auth_url.contains("code_challenge_method=S256"))
  assert_true(
    auth_url.contains(
      "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback",
    ),
  )
  assert_true(
    auth_url.contains("scope=openid%20profile%20email%20offline_access"),
  )
  match codex_extract_query_param(auth_url, "state") {
    Some(state) => assert_eq(state.length(), 22)
    None => fail("authorize URL must carry state")
  }
  // The exchange POST hits /oauth/token with the authorization-code grant.
  assert_eq(transport_impl.requests.length(), 1)
  let exchange = transport_impl.requests[0]
  assert_eq(exchange.url, "https://auth.openai.com/oauth/token")
  assert_eq(
    codex_extract_query_param(exchange.body, "grant_type"),
    Some("authorization_code"),
  )
  assert_eq(
    codex_extract_query_param(exchange.body, "client_id"),
    Some("app_EMoamEEZ73f0CkXaXp7hrann"),
  )
  assert_eq(codex_extract_query_param(exchange.body, "code"), Some("the_code"))
  match codex_extract_query_param(exchange.body, "code_verifier") {
    Some(verifier) => assert_true(verifier.length() > 0)
    None => fail("exchange body must carry a code_verifier")
  }
  assert_eq(
    codex_extract_query_param(exchange.body, "redirect_uri"),
    Some("http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"),
  )
  // The strict parser extracted the JWT account claim into metadata.
  assert_eq(credential.metadata.get("account_id"), Some("acct-123"))
  assert_eq(credential.refresh_token, "refresh-next")
  assert_eq(server_impl.started_ports, [1455])
  assert_eq(server_impl.stop_count, 1)
}

///|
async test "codex login rejects a forged callback state" {
  let interaction_impl = CodexRecordingInteraction::{ last_auth_url: "", }
  let server_impl = CodexFakeCallbackServer::{
    interaction: interaction_impl,
    delivered_code: "the_code",
    forged_state: true,
    started_ports: [],
    stop_count: 0,
  }
  let transport_impl = CodexRecordingTransport::{
    requests: [],
    responses: [
      @oauth.OAuthHttpResponse::{
        status: 200,
        body: codex_browser_token_response(),
      },
    ],
  }
  let interaction : &@oauth.AuthInteraction = interaction_impl
  let server : &@oauth.CallbackServer = server_impl
  let transport : &@oauth.OAuthHttpTransport = transport_impl
  let oauth = CodexOAuth::CodexOAuth(transport=Some(transport))
  let result = Ok(oauth.run_browser_login(interaction, server)) catch {
    e => Err(e)
  }
  match result {
    Err(@oauth.OAuthError::ParseError(detail)) =>
      assert_true(detail.contains("oauth state mismatch"))
    _ => fail("a forged callback state must raise ParseError")
  }
  assert_eq(transport_impl.requests.length(), 0)
  assert_eq(server_impl.stop_count, 1)
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
      // Second call: the best-effort usage probe rides the same transport.
      OpenAIModelsHttpResponse::{
        status: 200,
        body: "{\"rate_limit\":{\"primary_window\":{\"used_percent\":10.0,\"limit_window_seconds\":18000,\"reset_at\":1777936568}}}",
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
  // The refresh also probes the usage endpoint on the same transport so the
  // 5h/weekly snapshot starts populated without model traffic.
  assert_eq(
    transport_impl.urls[1],
    "https://chatgpt.com/backend-api/wham/usage",
  )
}

///|
test "openai reasoning effort is carried in responses request body" {
  let body = build_request_body(
    [],
    [],
    { temperature: None, max_output_tokens: None, },
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
  let items = @responses.message_to_responses_items(msg)
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
  let items = @responses.message_to_responses_items(msg)
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
  let resp = @responses.parse_responses_response(provider="OpenAI", resp_json)
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
  let sink = @responses.SseStreamState::SseStreamState()
  let completed =
    #|{"type":"response.completed","response":{"status":"completed","output":[{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"s"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}]}}
  assert_true(
    @responses.process_responses_sse(
      provider="OpenAI",
      completed,
      acc,
      fn(_) { () },
      state=sink,
    ),
  )
  let completion = attach_reasoning_items_responses(acc.to_completion(), sink)
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
    for item in @responses.message_to_responses_items(m) {
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
  match @responses.extract_usage(provider="OpenAI", resp) {
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
  match @responses.extract_usage(provider="OpenAI", no_details) {
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
  let outcome : Result[@posoco.Usage?, Error] = Ok(
    @responses.extract_usage(provider="OpenAI", bad_details),
  ) catch {
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
      CodexReasoningLevel::{ effort: "medium", description: "balanced", },
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

///|
/// Codex subscription config for the identity header tests: the base URL
/// equals the Codex OAuth endpoint so build_headers takes the protocol path.
fn codex_identity_test_config() -> OpenAIConfig {
  let config = OpenAIConfig::with_base_url(
    codex_test_access_token(),
    "gpt-5",
    codex_oauth_api_base(),
  )
  { ..config, account_id: Some("acct-123"), }
}

///|
test "codex subscription headers carry the posoco identity in official shape" {
  let config = codex_identity_test_config()
  let headers = build_headers(config, Some("sess-1"), true, false)
  assert_eq(headers.get("originator"), Some("posoco"))
  match headers.get("User-Agent") {
    Some(ua) => assert_true(ua.has_prefix("posoco/ext-openai ("))
    None => fail("expected a posoco User-Agent")
  }
  assert_eq(headers.get("session-id"), Some("sess-1"))
  assert_eq(headers.get("x-codex-window-id"), Some("sess-1:0"))
  assert_eq(headers.get("Accept"), Some("text/event-stream"))
  assert_eq(headers.get("chatgpt-account-id"), Some("acct-123"))
  match (headers.get("thread-id"), headers.get("x-client-request-id")) {
    (Some(thread), Some(request)) => {
      assert_true(thread.length() > 0)
      assert_eq(thread, request)
    }
    _ => fail("thread-id and x-client-request-id must both be present")
  }
  let replayed = build_headers(config, Some("sess-1"), true, false)
  assert_eq(replayed.get("session-id"), Some("sess-1"))
  match (headers.get("thread-id"), replayed.get("thread-id")) {
    (Some(first), Some(second)) => assert_true(first != second)
    _ => fail("thread-id must be minted per call")
  }
}

///|
test "codex compact headers add a stable installation id" {
  let config = codex_identity_test_config()
  let first = build_headers(config, Some("sess-2"), false, true)
  let second = build_headers(config, Some("sess-2"), false, true)
  assert_eq(first.get("Accept"), Some("application/json"))
  match
    (
      first.get("x-codex-installation-id"),
      second.get("x-codex-installation-id"),
    ) {
    (Some(first_id), Some(second_id)) => {
      assert_true(first_id.length() > 0)
      assert_eq(first_id, second_id)
    }
    _ => fail("compact codex calls must carry a stable installation id")
  }
  let plain = build_headers(config, Some("sess-2"), false, false)
  assert_true(plain.get("x-codex-installation-id") is None)
}

///|
test "api key base url gets the user agent but no codex protocol headers" {
  let config = OpenAIConfig::with_base_url(
    "sk-test", "gpt-5", "https://api.openai.com/v1",
  )
  let headers = build_headers(config, Some("sess-3"), true, false)
  match headers.get("User-Agent") {
    Some(ua) => assert_true(ua.has_prefix("posoco/ext-openai ("))
    None => fail("expected a posoco User-Agent")
  }
  assert_true(headers.get("originator") is None)
  assert_true(headers.get("session-id") is None)
  assert_true(headers.get("x-codex-window-id") is None)
  assert_true(headers.get("thread-id") is None)
}

///|
test "identity user agent formats the platform triple" {
  assert_eq(
    identity_user_agent(platform="darwin", release="24.5.0", arch="arm64"),
    "posoco/ext-openai (darwin 24.5.0; arm64)",
  )
}

///|
async test "codex model fetch sends originator and user agent" {
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
        "{\"effort\":\"medium\",\"description\":\"balanced\"}]," +
        "\"visibility\":\"list\",\"supported_in_api\":true,\"priority\":1," +
        "\"context_window\":272000}]}",
      },
    ],
  }
  let transport : &OpenAIModelsHttpTransport = transport_impl
  let models = fetch_codex_models_with_transport(
    transport,
    codex_oauth_api_base(),
    codex_test_access_token(),
    "acct-123",
    openai_codex_models_client_version(),
  )
  assert_eq(models.length(), 1)
  assert_eq(transport_impl.headers[0].get("originator"), Some("posoco"))
  match transport_impl.headers[0].get("User-Agent") {
    Some(ua) => assert_true(ua.has_prefix("posoco/ext-openai ("))
    None => fail("expected a posoco User-Agent on codex model fetch")
  }
}

///|
/// A path-bearing base_url must not fail URL resolution when the transport
/// opens its client: `@http.Client::Client` rejects URIs with a path, so the
/// adapter must connect to the origin and carry the path into request paths.
/// Loopback discard port keeps this offline: URL resolution must succeed and
/// only the TCP connect may fail — never stage=create_client InvalidFormat.
async test "openai path-bearing base_url connects to the origin" {
  let config = OpenAIConfig::with_base_url(
    "k", "gpt-5", "https://127.0.0.1:9/v1",
  )
  let port = OpenAIModelPort::OpenAIModelPort(config)
  let options : @posoco.ChatOptions = {
    temperature: None,
    max_output_tokens: None,
  }
  let nonstream = Ok(port.chat_nonstream("s1", [], [], options)) catch {
    err => Err(err)
  }
  match nonstream {
    Err(@posoco.ModelError::Transport(message)) =>
      assert_true(!message.contains("InvalidFormat"))
    Err(_) => fail("expected a transport error from non-stream chat")
    Ok(_) => fail("loopback discard port must not accept a connection")
  }
  let streamed = Ok(port.chat_stream("s2", [], [], options, _ => ())) catch {
    err => Err(err)
  }
  match streamed {
    Err(@posoco.ModelError::Transport(message)) =>
      assert_true(!message.contains("InvalidFormat"))
    Err(_) => fail("expected a transport error from streaming chat")
    Ok(_) => fail("loopback discard port must not accept a connection")
  }
}

///|
test "openai base_url splits into origin and endpoint path prefix" {
  let cases : Array[(String, String, String)] = [
    ("https://api.openai.com/v1", "https://api.openai.com", "/v1"),
    (
      "https://chatgpt.com/backend-api/codex", "https://chatgpt.com", "/backend-api/codex",
    ),
    ("https://api.openai.com", "https://api.openai.com", ""),
    ("https://api.openai.com/", "https://api.openai.com", ""),
    ("https://api.openai.com/v1/", "https://api.openai.com", "/v1"),
    ("http://host.example:8080/prefix", "http://host.example:8080", "/prefix"),
  ]
  for entry in cases {
    let (base_url, origin, prefix) = entry
    let (got_origin, got_prefix) = split_openai_base_url(base_url)
    assert_eq(got_origin, origin)
    assert_eq(got_prefix, prefix)
  }
  let schemeless = Ok(split_openai_base_url("api.openai.com/v1")) catch {
    err => Err(err)
  }
  match schemeless {
    Err(@posoco.ModelError::Transport(_)) => ()
    _ => fail("scheme-less base_url must be a typed transport error")
  }
}

///|
/// Reasoning-model requests must not carry temperature: the Codex backend
/// rejects it with 400 `{"detail":"Unsupported parameter: temperature"}` for
/// the gpt-5 family, and hosts tune temperature=0.0 by default. The strip is
/// keyed on reasoning effort presence — the provider-owned signal that the
/// selected model is a reasoning model. Plain models keep the passthrough.
test "openai reasoning requests drop unsupported temperature" {
  let tuned : @posoco.ChatOptions = {
    temperature: Some(0.0),
    max_output_tokens: None,
  }
  match build_request_body([], [], tuned, "gpt-5.6-luna", Some("max")) {
    Json::Object(fields) => {
      let absent : Json? = None
      assert_eq(fields.get("temperature"), absent)
    }
    _ => fail("Responses request body must be an object")
  }
  match build_request_body([], [], tuned, "gpt-4o", None) {
    Json::Object(fields) =>
      assert_eq(fields.get("temperature"), Some(Json::number(0.0)))
    _ => fail("Responses request body must be an object")
  }
}

///|
/// 429 quota verdict: the Codex usage-limit body raises the typed
/// RateLimited with the provider code and the stated reset time, so the
/// RateLimitGuard can schedule resume.
test "openai 429 codex body raises rate limited with reset" {
  let body =
    #|{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","plan_type":"plus","resets_at":1788506102,"resets_in_seconds":4317,"eligible_promo":null}}
  match openai_quota_verdict(429, Some(body), None, now_ms=1788501785000L) {
    Some(@posoco.ModelError::RateLimited(info)) => {
      assert_eq(info.provider_code, Some("usage_limit_reached"))
      assert_eq(info.reset_at_ms, Some(1788501785000L + 4317000L))
      assert_true(info.message.length() > 0)
    }
    _ => fail("a codex 429 body must raise RateLimited")
  }
}

///|
/// Without `resets_in_seconds`, the absolute `resets_at` epoch seconds
/// still yields the wall-clock reset time.
test "openai 429 resets_at-only body uses the absolute epoch" {
  let body =
    #|{"error":{"type":"usage_limit_reached","resets_at":1788506102}}
  match openai_quota_verdict(429, Some(body), None, now_ms=1788501785000L) {
    Some(@posoco.ModelError::RateLimited(info)) =>
      assert_eq(info.reset_at_ms, Some(1788506102000L))
    _ => fail("a resets_at-only 429 body must raise RateLimited")
  }
}

///|
/// Non-429 statuses never take the quota verdict, even when the body
/// itself carries quota-shaped fields.
test "openai non-429 statuses are not quota-classified" {
  let body =
    #|{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","plan_type":"plus","resets_at":1788506102,"resets_in_seconds":4317,"eligible_promo":null}}
  assert_true(
    openai_quota_verdict(500, Some(body), None, now_ms=1788501785000L) is None,
  )
  assert_true(
    openai_quota_verdict(401, Some(body), None, now_ms=1788501785000L) is None,
  )
}

///|
/// Every 429 raises RateLimited even when the body never drained: the
/// guard's probe backoff handles the missing reset time.
test "openai 429 without a body still raises rate limited" {
  match openai_quota_verdict(429, None, None, now_ms=1788501785000L) {
    Some(@posoco.ModelError::RateLimited(info)) =>
      assert_true(info.reset_at_ms is None)
    _ => fail("an empty 429 must still raise RateLimited")
  }
}

///|
/// The transport sites forward the Retry-After header verbatim; a numeric
/// seconds value becomes the wall-clock reset time.
test "openai 429 retry-after header yields the reset time" {
  match openai_quota_verdict(429, None, Some("120"), now_ms=1788501785000L) {
    Some(@posoco.ModelError::RateLimited(info)) =>
      assert_eq(info.reset_at_ms, Some(1788501785000L + 120000L))
    _ => fail("a Retry-After 429 must raise RateLimited")
  }
}

///|
/// Real-wire corpus regression: two SSE streams captured verbatim from the
/// Codex backend (chatgpt.com/backend-api/codex/responses), one low-effort
/// with a single function_call at output_index 0, one effort=max where a
/// reasoning item occupies output_index 0 and the function_call sits at
/// output_index 1. Guards the wire-format contract end to end: compact
/// tool-slot remapping, done-event identity/reasoning capture, terminal
/// output[]=[] tolerance, and the wire-spelled finish reason.
test "openai real codex sse corpus replays to tool calls" {
  let low : Array[String] = [
    "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_008857c78e9d01d9016a9aa0c0f46087d09cfa811241826e0b\",\"object\":\"response\",\"created_at\":1788518592,\"status\":\"in_progress\",\"background\":false,\"completed_at\":null,\"error\":null,\"frequency_penalty\":0.0,\"incomplete_details\":null,\"instructions\":null,\"max_output_tokens\":null,\"max_tool_calls\":null,\"model\":\"gpt-5.6-luna\",\"moderation\":null,\"output\":[],\"parallel_tool_calls\":true,\"presence_penalty\":0.0,\"previous_response_id\":null,\"prompt_cache_key\":\"ca49177b-a23d-43a4-aa99-3545bced5593\",\"prompt_cache_retention\":\"24h\",\"reasoning\":{\"context\":\"all_turns\",\"effort\":\"low\",\"mode\":\"standard\",\"summary\":\"detailed\"},\"safety_identifier\":\"user-gATLXyx4Z9rsYLTJq8Vbp86K\",\"service_tier\":\"auto\",\"store\":false,\"temperature\":1.0,\"text\":{\"format\":{\"type\":\"text\"},\"verbosity\":\"medium\"},\"tool_choice\":\"auto\",\"tool_usage\":{\"image_gen\":{\"input_tokens\":0,\"input_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"output_tokens\":0,\"output_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"total_tokens\":0},\"web_search\":{\"num_requests\":0}},\"tools\":[{\"type\":\"function\",\"description\":\"Read a file from disk\",\"name\":\"read\",\"output_schema\":null,\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"],\"additionalProperties\":false},\"strict\":true}],\"top_logprobs\":0,\"top_p\":0.98,\"truncation\":\"disabled\",\"usage\":null,\"user\":null,\"metadata\":{}},\"sequence_number\":0}",
    "{\"type\":\"response.in_progress\",\"response\":{\"id\":\"resp_008857c78e9d01d9016a9aa0c0f46087d09cfa811241826e0b\",\"object\":\"response\",\"created_at\":1788518592,\"status\":\"in_progress\",\"background\":false,\"completed_at\":null,\"error\":null,\"frequency_penalty\":0.0,\"incomplete_details\":null,\"instructions\":null,\"max_output_tokens\":null,\"max_tool_calls\":null,\"model\":\"gpt-5.6-luna\",\"moderation\":null,\"output\":[],\"parallel_tool_calls\":true,\"presence_penalty\":0.0,\"previous_response_id\":null,\"prompt_cache_key\":\"ca49177b-a23d-43a4-aa99-3545bced5593\",\"prompt_cache_retention\":\"24h\",\"reasoning\":{\"context\":\"all_turns\",\"effort\":\"low\",\"mode\":\"standard\",\"summary\":\"detailed\"},\"safety_identifier\":\"user-gATLXyx4Z9rsYLTJq8Vbp86K\",\"service_tier\":\"auto\",\"store\":false,\"temperature\":1.0,\"text\":{\"format\":{\"type\":\"text\"},\"verbosity\":\"medium\"},\"tool_choice\":\"auto\",\"tool_usage\":{\"image_gen\":{\"input_tokens\":0,\"input_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"output_tokens\":0,\"output_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"total_tokens\":0},\"web_search\":{\"num_requests\":0}},\"tools\":[{\"type\":\"function\",\"description\":\"Read a file from disk\",\"name\":\"read\",\"output_schema\":null,\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"],\"additionalProperties\":false},\"strict\":true}],\"top_logprobs\":0,\"top_p\":0.98,\"truncation\":\"disabled\",\"usage\":null,\"user\":null,\"metadata\":{}},\"sequence_number\":1}",
    "{\"type\":\"response.output_item.added\",\"item\":{\"id\":\"fc_008857c78e9d01d9016a9aa0c1893887d0ba5cd82b1205db86\",\"type\":\"function_call\",\"status\":\"in_progress\",\"arguments\":\"\",\"call_id\":\"call_2SYz207Bokbi9hdogto3t7DC\",\"name\":\"read\"},\"output_index\":0,\"sequence_number\":2}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"\",\"item_id\":\"fc_008857c78e9d01d9016a9aa0c1893887d0ba5cd82b1205db86\",\"obfuscation\":\"A5I1GSOwJqaOEO\",\"output_index\":0,\"sequence_number\":3}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"path\",\"item_id\":\"fc_008857c78e9d01d9016a9aa0c1893887d0ba5cd82b1205db86\",\"obfuscation\":\"Uxug5HWNB4Hy\",\"output_index\":0,\"sequence_number\":4}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\":\",\"item_id\":\"fc_008857c78e9d01d9016a9aa0c1893887d0ba5cd82b1205db86\",\"obfuscation\":\"iQog7NP1a1HmIW\",\"output_index\":0,\"sequence_number\":5}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\"/\",\"item_id\":\"fc_008857c78e9d01d9016a9aa0c1893887d0ba5cd82b1205db86\",\"obfuscation\":\"d0wRTiiCxFPXos\",\"output_index\":0,\"sequence_number\":6}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"tmp\",\"item_id\":\"fc_008857c78e9d01d9016a9aa0c1893887d0ba5cd82b1205db86\",\"obfuscation\":\"ThROfIyHkz8JT\",\"output_index\":0,\"sequence_number\":7}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"/\",\"item_id\":\"fc_008857c78e9d01d9016a9aa0c1893887d0ba5cd82b1205db86\",\"obfuscation\":\"V7WkWaL53i5FqMA\",\"output_index\":0,\"sequence_number\":8}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"notes\",\"item_id\":\"fc_008857c78e9d01d9016a9aa0c1893887d0ba5cd82b1205db86\",\"obfuscation\":\"dA5bVBlzVEO\",\"output_index\":0,\"sequence_number\":9}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\".txt\",\"item_id\":\"fc_008857c78e9d01d9016a9aa0c1893887d0ba5cd82b1205db86\",\"obfuscation\":\"N9lHYrlKEDFc\",\"output_index\":0,\"sequence_number\":10}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\"}\",\"item_id\":\"fc_008857c78e9d01d9016a9aa0c1893887d0ba5cd82b1205db86\",\"obfuscation\":\"4jUypIEpSCiluw\",\"output_index\":0,\"sequence_number\":11}",
    "{\"type\":\"response.function_call_arguments.done\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/notes.txt\\\"}\",\"item_id\":\"fc_008857c78e9d01d9016a9aa0c1893887d0ba5cd82b1205db86\",\"output_index\":0,\"sequence_number\":12}",
    "{\"type\":\"response.output_item.done\",\"item\":{\"id\":\"fc_008857c78e9d01d9016a9aa0c1893887d0ba5cd82b1205db86\",\"type\":\"function_call\",\"status\":\"completed\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/notes.txt\\\"}\",\"call_id\":\"call_2SYz207Bokbi9hdogto3t7DC\",\"name\":\"read\"},\"output_index\":0,\"sequence_number\":13}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_008857c78e9d01d9016a9aa0c0f46087d09cfa811241826e0b\",\"object\":\"response\",\"created_at\":1788518592,\"status\":\"completed\",\"background\":false,\"completed_at\":1788518593,\"error\":null,\"frequency_penalty\":0.0,\"incomplete_details\":null,\"instructions\":null,\"max_output_tokens\":null,\"max_tool_calls\":null,\"model\":\"gpt-5.6-luna\",\"moderation\":null,\"output\":[],\"parallel_tool_calls\":true,\"presence_penalty\":0.0,\"previous_response_id\":null,\"prompt_cache_key\":\"ca49177b-a23d-43a4-aa99-3545bced5593\",\"prompt_cache_retention\":\"24h\",\"reasoning\":{\"context\":\"all_turns\",\"effort\":\"low\",\"mode\":\"standard\",\"summary\":\"detailed\"},\"safety_identifier\":\"user-gATLXyx4Z9rsYLTJq8Vbp86K\",\"service_tier\":\"default\",\"store\":false,\"temperature\":1.0,\"text\":{\"format\":{\"type\":\"text\"},\"verbosity\":\"medium\"},\"tool_choice\":\"auto\",\"tool_usage\":{\"image_gen\":{\"input_tokens\":0,\"input_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"output_tokens\":0,\"output_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"total_tokens\":0},\"web_search\":{\"num_requests\":0}},\"tools\":[{\"type\":\"function\",\"description\":\"Read a file from disk\",\"name\":\"read\",\"output_schema\":null,\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"],\"additionalProperties\":false},\"strict\":true}],\"top_logprobs\":0,\"top_p\":0.98,\"truncation\":\"disabled\",\"usage\":{\"attribution\":{\"items\":{\"msg_008857c78e9d01d9016a9aa0c0fd8887d0b796ebe792b7dde3\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"content\":[{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":30,\"output_tokens\":0}],\"input_tokens\":30,\"output_tokens\":0},\"fc_008857c78e9d01d9016a9aa0c1893887d0ba5cd82b1205db86\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":2,\"output_tokens\":21}},\"request_fields\":{\"tools\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":39,\"output_tokens\":0}}},\"input_tokens\":71,\"input_tokens_details\":{\"cache_write_tokens\":0,\"cached_tokens\":0},\"output_tokens\":21,\"output_tokens_details\":{\"reasoning_tokens\":0},\"total_tokens\":92},\"user\":null,\"metadata\":{}},\"sequence_number\":14}",
  ]
  let max_effort : Array[String] = [
    "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_0d81078b3c2499f2016a9aa0f7a52887d09725658467e92b66\",\"object\":\"response\",\"created_at\":1788518647,\"status\":\"in_progress\",\"background\":false,\"completed_at\":null,\"error\":null,\"frequency_penalty\":0.0,\"incomplete_details\":null,\"instructions\":null,\"max_output_tokens\":null,\"max_tool_calls\":null,\"model\":\"gpt-5.6-luna\",\"moderation\":null,\"output\":[],\"parallel_tool_calls\":true,\"presence_penalty\":0.0,\"previous_response_id\":null,\"prompt_cache_key\":\"2ff3076c-3be0-48be-acb6-a4f41239777d\",\"prompt_cache_retention\":\"24h\",\"reasoning\":{\"context\":\"all_turns\",\"effort\":\"max\",\"mode\":\"standard\",\"summary\":\"detailed\"},\"safety_identifier\":\"user-gATLXyx4Z9rsYLTJq8Vbp86K\",\"service_tier\":\"auto\",\"store\":false,\"temperature\":1.0,\"text\":{\"format\":{\"type\":\"text\"},\"verbosity\":\"medium\"},\"tool_choice\":\"auto\",\"tool_usage\":{\"image_gen\":{\"input_tokens\":0,\"input_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"output_tokens\":0,\"output_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"total_tokens\":0},\"web_search\":{\"num_requests\":0}},\"tools\":[{\"type\":\"function\",\"description\":\"Read a file from disk\",\"name\":\"read\",\"output_schema\":null,\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"],\"additionalProperties\":false},\"strict\":true}],\"top_logprobs\":0,\"top_p\":0.98,\"truncation\":\"disabled\",\"usage\":null,\"user\":null,\"metadata\":{}},\"sequence_number\":0}",
    "{\"type\":\"response.in_progress\",\"response\":{\"id\":\"resp_0d81078b3c2499f2016a9aa0f7a52887d09725658467e92b66\",\"object\":\"response\",\"created_at\":1788518647,\"status\":\"in_progress\",\"background\":false,\"completed_at\":null,\"error\":null,\"frequency_penalty\":0.0,\"incomplete_details\":null,\"instructions\":null,\"max_output_tokens\":null,\"max_tool_calls\":null,\"model\":\"gpt-5.6-luna\",\"moderation\":null,\"output\":[],\"parallel_tool_calls\":true,\"presence_penalty\":0.0,\"previous_response_id\":null,\"prompt_cache_key\":\"2ff3076c-3be0-48be-acb6-a4f41239777d\",\"prompt_cache_retention\":\"24h\",\"reasoning\":{\"context\":\"all_turns\",\"effort\":\"max\",\"mode\":\"standard\",\"summary\":\"detailed\"},\"safety_identifier\":\"user-gATLXyx4Z9rsYLTJq8Vbp86K\",\"service_tier\":\"auto\",\"store\":false,\"temperature\":1.0,\"text\":{\"format\":{\"type\":\"text\"},\"verbosity\":\"medium\"},\"tool_choice\":\"auto\",\"tool_usage\":{\"image_gen\":{\"input_tokens\":0,\"input_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"output_tokens\":0,\"output_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"total_tokens\":0},\"web_search\":{\"num_requests\":0}},\"tools\":[{\"type\":\"function\",\"description\":\"Read a file from disk\",\"name\":\"read\",\"output_schema\":null,\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"],\"additionalProperties\":false},\"strict\":true}],\"top_logprobs\":0,\"top_p\":0.98,\"truncation\":\"disabled\",\"usage\":null,\"user\":null,\"metadata\":{}},\"sequence_number\":1}",
    "{\"type\":\"response.output_item.added\",\"item\":{\"id\":\"rs_0d81078b3c2499f2016a9aa0f8235087d0893a6f9ff93ba895\",\"type\":\"reasoning\",\"content\":[],\"encrypted_content\":\"gAAAAABqmqD4a1UJJCt-iMxZjtqaXhuqB1-0EMAcKiC2_5qwyZgElE3K82_fmO1zFgrXl5VBx2P-CRlpYZYFXS6zZ5xNH6-8RILEcOcBwMzPLvqZtTRTbUgxbn1WIMlPz9Asz6cRvbchrlD-rAVVhAVwSTBriM8Wjw7L2OwVeSCs-g6KctRaxLhOW5vC6fscBGVOvau5UHBVBuRyIRu8cKNSBi-4_KttpFEVNNzp4W94YUMmfYuXCMVyCV7td9CbNBp0O2ASAHDJmy3Xw3dxcIw2tLBMjsuuRMk4C9e5AXDfG_kdQSGpzFGMQm3_6D-Nvk4FtBYK679ltQsr7Tx-SRlMCGVMyqilkJ_NwfheTpHl070_2stg7bUUel6KGbZrE3uxrZOj6lDxo2rPRHmc73xvPuFAuOQpbQNVr7eaDe3reJOvVvfNV3hzl7SlvUNve-PpvCh_yX10ZEOfiZO8e87Xui2XyuWpDpQSdyyjPi1Glg-L6BuG991vbZTum6YRx_SCFO_uA1llANdn63LaaiRQefS321NhIdhtThgCMhH87N4alx3baJ6U_ju41tMRodGpEk7fziTc5KhyWaHHd2XDktVptCZEiPoMNrtUPfM1eylQwX8SXUTif7jzHwo3bYkHt7jyvawJaFXnqbKHbwWm9isrlDJN9oLPSb7UwajdvYNP8oI6TtcAJTWrdv5lh4XS8Q6fAeNuUQZZoXzP83r7tJudcVktkDP-u79A-tZhTxwwexWw7e_62hLyiZ6U8sgVrkbaNeuWcjou6IqmCJKa6mE4pHKCaNPcCCFoIdGhTPVnvWswV8SI9BxZq7epw3FZ6zKu1y2QprdLMDKoX34wn1SZL2eKQK51bC67B3ifHPxRffp4oC0wvV2Wz4G73obntYFy1CEw29J-csD66ZVKrvbgDzunsUdO3wfegLICynWwd0ShDAxy-Zx2aHudTSq3PtvJsZDUC2drwZW4xVETV38s78RHsgtQ2TiJS7qPALW50GxwJ4CNgl9zbm26brW5AFNUv1fj0du9aIor2ygwJLws8LE57p_G0cxTx4gBoH3A1PP5wgR5WOmXSWKc-p3FbW8iN3EaPd9Q9ie-3Jo3vGH0RMk_aDBU0-2bwDGEDFHQM07jCKf1lhrVu00bF5QugIxsae9cw6JVAGcPW91Mi7rBIrim3kSOFa1Qc9ZoFXPCgujeJGC1aWeGKZ2-sTgfzXxlBpR6KKzcEDIDhIc8k_l6Fvc0Ir-ebMQDV0y_aM4hLVxTs95WpiwNMn4mp8nPTd1HHQDh\",\"summary\":[]},\"output_index\":0,\"sequence_number\":2}",
    "{\"type\":\"response.output_item.done\",\"item\":{\"id\":\"rs_0d81078b3c2499f2016a9aa0f8235087d0893a6f9ff93ba895\",\"type\":\"reasoning\",\"content\":[],\"encrypted_content\":\"gAAAAABqmqD4dhs8phR8PwuvgVTT7qzeX2H44uR66sZE6-FfGp-R7LFFjmjdHyZ8KNy0VFRzHSoDj_QrKabuqVnI9qH8wgImd-P97ja-_bMz0Kml9HzSEnTvVtl4e87PF-YzodNim_5PQybMlPIWx2dlNFeY-XCzOQsAgmuYIAegqvvyIv5mZauc7qfm5jwkn30AL71OFD4u6IGCacpe3hKhnQCBGiYuPgXg3rFcETRMOwfCmwLGtCwjcJIeLKpx0tQ-qHbevK86tU9sanXHrQpOHUJHGtycbFs81icrFlXeSfluvmhRNrrXIgbceJHsZcX_OLp3NKHKLhNmtmXmDcOkkk3Q46xN6HkGqOv_tisWORjM812e-iwY8Iw4IuuRJjP1KzwLx-CqwRzJwFhgu-4aq3_SJbombzRkU1rq8AtY1qslbwDR4pKPwgGbhao9UJuNPd2-i15SbrDAeahrTr6FohiRp14_RVab9Tgej4BjBYI_GKhK0oj4UIGRFIx0DP5PRKpoZNIO6M2-s11OgBhLcEA7dFiLJ0h-1EacYAnAqMw2nan6Pa33X4Q3y_OX4GF26EmmtvA9BCdlkffUtr1COE2pS4H-RelqTEB9EMIXFRe4sfe2vpYMM2wGUyI1nwM90VchUg10DNh_N_uRUcB1gEOn6fdgQeAwCMgIJ9nXlV9oqRhhsbCT-JhZj1iehI_OAEDDVG-TOyHhZR3ZcZC7f7mbvkQ2lZ_5Kks10xq2D5mLp_KFPFI9rY5nXSYsjOYKT-cawe8FeyimEqFc_FN9Fq_78TuZIe1rVLJ1ZOGF1zJIA7wU7gN0M3QoevTWzCsfH6y2sTudNkpjq5hRaZr1QMBzR2dBjIgpHXh-z9mrbmacx0v7VXdIEBD5wOkdcK3gn60JqPQo6gqJoXWMgstm9Oo1MQvw97XEdus2aAnP2XbaxyTWV_tzt6LU-lSRCMgXUOHzWkOQ4YFS-5WDr3pKl8sugtv8uMnfLU2LV5Y8ucoRkeWIvliwgNKFtNOwF9Hfk2O7ugScb1i96iF93kwWPNTlhETevanG4zcbZ-z9bLbWE55BGrM-T_4Ki_gyNfnmJhySSDI84XmkwIGow69nvHSuDnJXGEgodN2ImweGToE1R6l-lC2dCnWSMPOfT0hNda9_t3ub-qASCnHWIZehfIkmf8w_c96UMONLLEieeopfx8_DliyqJURakmeF4c8kBvSJJni4mf0qDfJe1atBDJ5fvDVbPynTCxOvrD2ZO_HpFfQVgKcvUJEDzVT_ppXhEeiv7bxJbi5L2sauAtWBENBrCfV-KUb6jQ9UcuNqGFSVKs32RdZF5dsNGHlgGu3sHbOT4d2K\",\"summary\":[]},\"output_index\":0,\"sequence_number\":3}",
    "{\"type\":\"response.output_item.added\",\"item\":{\"id\":\"fc_0d81078b3c2499f2016a9aa0f8a01c87d0b9afcbba25bfe9bc\",\"type\":\"function_call\",\"status\":\"in_progress\",\"arguments\":\"\",\"call_id\":\"call_30EJclkSchD7GM6QyNCQLEZx\",\"name\":\"read\"},\"output_index\":1,\"sequence_number\":4}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"\",\"item_id\":\"fc_0d81078b3c2499f2016a9aa0f8a01c87d0b9afcbba25bfe9bc\",\"obfuscation\":\"DwK61JDARO8tCS\",\"output_index\":1,\"sequence_number\":5}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"path\",\"item_id\":\"fc_0d81078b3c2499f2016a9aa0f8a01c87d0b9afcbba25bfe9bc\",\"obfuscation\":\"aFxfhDD462CJ\",\"output_index\":1,\"sequence_number\":6}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\":\",\"item_id\":\"fc_0d81078b3c2499f2016a9aa0f8a01c87d0b9afcbba25bfe9bc\",\"obfuscation\":\"LC1wWTY0xodjsF\",\"output_index\":1,\"sequence_number\":7}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\"/\",\"item_id\":\"fc_0d81078b3c2499f2016a9aa0f8a01c87d0b9afcbba25bfe9bc\",\"obfuscation\":\"aVD7Z3TbLjO30S\",\"output_index\":1,\"sequence_number\":8}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"tmp\",\"item_id\":\"fc_0d81078b3c2499f2016a9aa0f8a01c87d0b9afcbba25bfe9bc\",\"obfuscation\":\"KQkQkgkTcywKR\",\"output_index\":1,\"sequence_number\":9}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"/\",\"item_id\":\"fc_0d81078b3c2499f2016a9aa0f8a01c87d0b9afcbba25bfe9bc\",\"obfuscation\":\"lvn6mDSVRKJ8vah\",\"output_index\":1,\"sequence_number\":10}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"notes\",\"item_id\":\"fc_0d81078b3c2499f2016a9aa0f8a01c87d0b9afcbba25bfe9bc\",\"obfuscation\":\"B62jdGxIRYO\",\"output_index\":1,\"sequence_number\":11}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\".txt\",\"item_id\":\"fc_0d81078b3c2499f2016a9aa0f8a01c87d0b9afcbba25bfe9bc\",\"obfuscation\":\"yU3B2fQFzr1B\",\"output_index\":1,\"sequence_number\":12}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\"}\",\"item_id\":\"fc_0d81078b3c2499f2016a9aa0f8a01c87d0b9afcbba25bfe9bc\",\"obfuscation\":\"KUURc6qDo3HPqH\",\"output_index\":1,\"sequence_number\":13}",
    "{\"type\":\"response.function_call_arguments.done\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/notes.txt\\\"}\",\"item_id\":\"fc_0d81078b3c2499f2016a9aa0f8a01c87d0b9afcbba25bfe9bc\",\"output_index\":1,\"sequence_number\":14}",
    "{\"type\":\"response.output_item.done\",\"item\":{\"id\":\"fc_0d81078b3c2499f2016a9aa0f8a01c87d0b9afcbba25bfe9bc\",\"type\":\"function_call\",\"status\":\"completed\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/notes.txt\\\"}\",\"call_id\":\"call_30EJclkSchD7GM6QyNCQLEZx\",\"name\":\"read\"},\"output_index\":1,\"sequence_number\":15}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_0d81078b3c2499f2016a9aa0f7a52887d09725658467e92b66\",\"object\":\"response\",\"created_at\":1788518647,\"status\":\"completed\",\"background\":false,\"completed_at\":1788518648,\"error\":null,\"frequency_penalty\":0.0,\"incomplete_details\":null,\"instructions\":null,\"max_output_tokens\":null,\"max_tool_calls\":null,\"model\":\"gpt-5.6-luna\",\"moderation\":null,\"output\":[],\"parallel_tool_calls\":true,\"presence_penalty\":0.0,\"previous_response_id\":null,\"prompt_cache_key\":\"2ff3076c-3be0-48be-acb6-a4f41239777d\",\"prompt_cache_retention\":\"24h\",\"reasoning\":{\"context\":\"all_turns\",\"effort\":\"max\",\"mode\":\"standard\",\"summary\":\"detailed\"},\"safety_identifier\":\"user-gATLXyx4Z9rsYLTJq8Vbp86K\",\"service_tier\":\"default\",\"store\":false,\"temperature\":1.0,\"text\":{\"format\":{\"type\":\"text\"},\"verbosity\":\"medium\"},\"tool_choice\":\"auto\",\"tool_usage\":{\"image_gen\":{\"input_tokens\":0,\"input_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"output_tokens\":0,\"output_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"total_tokens\":0},\"web_search\":{\"num_requests\":0}},\"tools\":[{\"type\":\"function\",\"description\":\"Read a file from disk\",\"name\":\"read\",\"output_schema\":null,\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"],\"additionalProperties\":false},\"strict\":true}],\"top_logprobs\":0,\"top_p\":0.98,\"truncation\":\"disabled\",\"usage\":{\"attribution\":{\"items\":{\"msg_0d81078b3c2499f2016a9aa0f7ad4c87d09664973bc16381a9\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"content\":[{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":30,\"output_tokens\":0}],\"input_tokens\":30,\"output_tokens\":0},\"rs_0d81078b3c2499f2016a9aa0f8235087d0893a6f9ff93ba895\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":2,\"output_tokens\":11},\"fc_0d81078b3c2499f2016a9aa0f8a01c87d0b9afcbba25bfe9bc\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":0,\"output_tokens\":23}},\"request_fields\":{\"tools\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":39,\"output_tokens\":0}}},\"input_tokens\":71,\"input_tokens_details\":{\"cache_write_tokens\":0,\"cached_tokens\":0},\"output_tokens\":34,\"output_tokens_details\":{\"reasoning_tokens\":11},\"total_tokens\":105},\"user\":null,\"metadata\":{}},\"sequence_number\":16}",
  ]
  // Low effort: function_call is the only output item (output_index 0).
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let st = @responses.SseStreamState::SseStreamState()
  let mut terminal = false
  for ev in low {
    if @responses.process_responses_sse(
        provider="OpenAI",
        ev,
        acc,
        _ => (),
        state=st,
      ) {
      terminal = true
    }
  }
  assert_true(terminal)
  @responses.validate_stream_tool_calls(provider="OpenAI", acc)
  let completion = attach_reasoning_items_responses(acc.to_completion(), st)
  let tool_calls = completion.tool_calls()
  assert_eq(tool_calls.length(), 1)
  assert_eq(tool_calls[0].call_id.to_string(), "call_2SYz207Bokbi9hdogto3t7DC")
  assert_eq(tool_calls[0].name.to_string(), "read")
  assert_eq(
    tool_calls[0].arguments.stringify(),
    "{\"path\":\"/tmp/notes.txt\"}",
  )
  assert_true(
    completion.message.finish_reason is @posoco.FinishReason::ToolCalls,
  )
  assert_eq(st.items.length(), 0)

  // Effort max: reasoning item at output_index 0, function_call at 1.
  // Guards the tool-slot remap: without it this stream shape raises
  // (stage=tool.id, category=missing) on turn one.
  let acc2 = @posoco.StreamAccumulator::StreamAccumulator()
  let st2 = @responses.SseStreamState::SseStreamState()
  let mut terminal2 = false
  for ev in max_effort {
    if @responses.process_responses_sse(
        provider="OpenAI",
        ev,
        acc2,
        _ => (),
        state=st2,
      ) {
      terminal2 = true
    }
  }
  assert_true(terminal2)
  @responses.validate_stream_tool_calls(provider="OpenAI", acc2)
  let completion2 = attach_reasoning_items_responses(acc2.to_completion(), st2)
  let tool_calls2 = completion2.tool_calls()
  assert_eq(tool_calls2.length(), 1)
  assert_eq(tool_calls2[0].call_id.to_string(), "call_30EJclkSchD7GM6QyNCQLEZx")
  assert_eq(tool_calls2[0].name.to_string(), "read")
  assert_eq(
    tool_calls2[0].arguments.stringify(),
    "{\"path\":\"/tmp/notes.txt\"}",
  )
  assert_true(
    completion2.message.finish_reason is @posoco.FinishReason::ToolCalls,
  )
  // The reasoning item (with encrypted_content) is captured exactly once from
  // its done event, ready for verbatim replay on the next request.
  assert_eq(st2.items.length(), 1)
  match st2.items[0] {
    Json::Object(item) => assert_true(item.contains("encrypted_content"))
    _ => fail("captured reasoning item must be an object")
  }
  // The replayed reasoning rides the completion for the next turn's input.
  assert_true(completion2.message.reasoning is Some(_))
}

///|
test "openai sse reasoning summary deltas stream as reasoning" {
  let events : Array[String] = [
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[],\"content\":[]}}",
    "{\"type\":\"response.reasoning_summary_part.added\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0}",
    "{\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"delta\":\"Think\"}",
    "{\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"delta\":\"ing\"}",
    "{\"type\":\"response.reasoning_summary_part.done\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0}",
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Thinking\"}],\"content\":[],\"encrypted_content\":\"enc\"}}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":100,\"output_tokens\":5,\"total_tokens\":105,\"input_tokens_details\":{\"cached_tokens\":40,\"cache_write_tokens\":0},\"output_tokens_details\":{\"reasoning_tokens\":2}}}}",
  ]
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let st = @responses.SseStreamState::SseStreamState()
  let chunks : Array[@posoco.StreamChunk] = []
  let mut terminal = false
  for ev in events {
    if @responses.process_responses_sse(
        provider="OpenAI",
        ev,
        acc,
        fn(c) { chunks.push(c) },
        state=st,
      ) {
      terminal = true
    }
  }
  assert_true(terminal)
  // Summary deltas (plus the part separator) surface as reasoning chunks.
  let reasoning_tokens = chunks.filter(fn(c) { c is ReasoningDelta(..) })
  assert_eq(reasoning_tokens.length(), 3)
  assert_true(reasoning_tokens[0] is ReasoningDelta(token="Think"))
  assert_true(reasoning_tokens[1] is ReasoningDelta(token="ing"))
  assert_true(reasoning_tokens[2] is ReasoningDelta(token="\n\n"))
  let completion = attach_reasoning_items_responses(acc.to_completion(), st)
  match completion.message.reasoning {
    Some(reasoning) => {
      assert_eq(reasoning.content, "Thinking\n\n")
      match reasoning.raw {
        Some(Json::Array(items)) => assert_eq(items.length(), 1)
        _ => fail("reasoning raw must carry the captured item")
      }
    }
    None => fail("reasoning must ride the completion")
  }
  // The completed usage reports the cached input share.
  match completion.usage {
    Some({ cached_input_tokens: Some(cached), input_tokens: Some(input), .. }) => {
      assert_eq(cached, 40)
      assert_eq(input, 100)
    }
    _ => fail("usage must ride the completion")
  }
}

///|
test "openai sse raw reasoning text streams and item content backfills" {
  let events : Array[String] = [
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"rs_2\",\"type\":\"reasoning\",\"summary\":[],\"content\":[]}}",
    "{\"type\":\"response.reasoning_text.delta\",\"item_id\":\"rs_2\",\"output_index\":0,\"content_index\":0,\"delta\":\"step one\"}",
    "{\"type\":\"response.reasoning_text.done\",\"item_id\":\"rs_2\",\"output_index\":0,\"content_index\":0,\"text\":\"step one\"}",
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"rs_2\",\"type\":\"reasoning\",\"summary\":[],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"step one\"}],\"encrypted_content\":\"enc2\"}}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_2\",\"status\":\"completed\",\"output\":[]}}",
  ]
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let st = @responses.SseStreamState::SseStreamState()
  let mut terminal = false
  for ev in events {
    if @responses.process_responses_sse(
        provider="OpenAI",
        ev,
        acc,
        _ => (),
        state=st,
      ) {
      terminal = true
    }
  }
  assert_true(terminal)
  let completion = attach_reasoning_items_responses(acc.to_completion(), st)
  match completion.message.reasoning {
    Some(reasoning) => assert_eq(reasoning.content, "step one")
    None => fail("reasoning must ride the completion")
  }
}

///|
test "openai extract_reasoning_items falls back to content text" {
  let item_without_summary : Json = {
    "type": "reasoning",
    "id": "rs_3",
    "summary": [],
    "content": [{ "type": "reasoning_text", "text": "visible raw thought" }],
  }
  let (raw, text) = @responses.extract_reasoning_items(
    provider="OpenAI",
    Json::array([item_without_summary]),
  )
  assert_eq(text, "visible raw thought")
  assert_eq(raw.length(), 1)
  // Summary text still wins when both are present.
  let item_with_summary : Json = {
    "type": "reasoning",
    "id": "rs_4",
    "summary": [{ "type": "summary_text", "text": "summary wins" }],
    "content": [{ "type": "reasoning_text", "text": "raw loses" }],
  }
  let (_, mixed) = @responses.extract_reasoning_items(
    provider="OpenAI",
    Json::array([item_with_summary]),
  )
  assert_eq(mixed, "summary wins")
}
