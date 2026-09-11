///|
fn user_msg(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
fn system_msg(text : String) -> @posoco.Message {
  @posoco.Message::SystemMessage(content=[@posoco.Content::Text(text)])
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
fn tool_msg(text : String) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_1"),
    tool_name=@posoco.ToolName::unchecked("read"),
    outcome=@posoco.ToolOutcome::Success(content=text, structured=None),
  )
}

///|
fn chat_options() -> @posoco.ChatOptions {
  { temperature: None, max_output_tokens: None, }
}

///|
fn tool_def(name : String) -> @posoco.ToolDef {
  @posoco.ToolDef::ToolDef(
    name=@posoco.ToolName::unchecked(name),
    description="test tool " + name,
    input_schema=Json::object({ "type": Json::string("object") }),
    owner=@posoco.OwnerId::unchecked("test"),
    policy=@posoco.ExecutionPolicy::Sequential,
    provenance=None,
  )
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
fn assert_json_field_number(
  obj : Map[String, Json],
  key : String,
  expected : Double,
) -> Unit raise {
  match obj.get(key) {
    Some(Number(n, ..)) => assert_eq(n, expected)
    _ => fail("expected number field: " + key)
  }
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
  let oauth_impl = KimiOAuth::KimiOAuth(
    transport=Some(transport),
    identity=Some(kimi_test_identity()),
  )
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
  let oauth_impl = KimiOAuth::KimiOAuth(
    transport=Some(transport),
    identity=Some(kimi_test_identity()),
  )
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
  let oauth_impl = KimiOAuth::KimiOAuth(
    transport=Some(transport),
    identity=Some(kimi_test_identity()),
  )
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
  let oauth_impl = KimiOAuth::KimiOAuth(
    transport=Some(transport),
    identity=Some(kimi_test_identity()),
  )
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
test "kimi_config_defaults_to_k3_platform_high_effort" {
  let config = KimiConfig("key")
  assert_eq(config.api_key, "key")
  assert_eq(config.base_url, "https://api.moonshot.ai/v1")
  assert_eq(config.model, "kimi-k3")
  assert_eq(config.reasoning_effort, "high")
  assert_eq(config.thinking_efforts, ["low", "high", "max"])
  assert_true(config.send_prompt_cache_key)
}

///|
test "kimi_effort_values_cover_the_k3_era_table" {
  for
    model in [
      "kimi-k3", "k3", "k3-256k", "kimi-for-coding", "kimi-for-coding-highspeed",
    ] {
    assert_eq(kimi_effort_values(model), ["low", "high", "max"])
  }
}

///|
test "model_policy_rejects_dropped_ids_with_migration_message" {
  for
    dropped in ["kimi-k2.7-code", "kimi-k2.6", "moonshot-v1-8k", "kimi-latest"] {
    match kimi_model_policy_error(dropped) {
      Some(message) => {
        assert_true(message.contains(dropped))
        assert_true(message.contains("removed with the k2 line"))
        assert_true(message.contains("kimi-k3"))
        assert_true(message.contains("k3-256k"))
        assert_true(message.contains("kimi-for-coding"))
      }
      None => fail("dropped model must produce the migration error: " + dropped)
    }
  }
  for
    supported in [
      "kimi-k3", "k3", "k3-256k", "kimi-for-coding", "kimi-for-coding-highspeed",
    ] {
    assert_true(kimi_model_policy_error(supported) is None)
  }
}

///|
test "responses_url_builds_responses_endpoint_on_both_hosts" {
  // Platform default: base_url already carries /v1.
  let platform = KimiConfig("key")
  assert_eq(responses_url(platform), "https://api.moonshot.ai/v1/responses")
  // Split spelling: origin + endpoint prefix.
  let split = KimiConfig(
    "key",
    base_url="https://api.moonshot.ai",
    endpoint_prefix="/v1",
  )
  assert_eq(responses_url(split), "https://api.moonshot.ai/v1/responses")
  // Managed coding host via OAuth credential.
  let credential = @oauth.Credential::Credential(
    access_token="tok",
    refresh_token="r",
    expires_at=1,
  )
  let coding = KimiConfig::from_oauth_credential(credential, "k3-256k")
  assert_eq(coding.base_url, "https://api.kimi.com/coding/v1")
  assert_eq(responses_url(coding), "https://api.kimi.com/coding/v1/responses")
}

///|
test "factory_defaults_coding_model_from_oauth_and_platform_from_api_key" {
  // OAuth credential without a model setting: kimi's own recommended
  // coding default applies.
  let oauth_credential = @oauth.Credential::Credential(
    access_token="tok",
    refresh_token="r",
    expires_at=1,
  )
  let oauth_source = @llm.ProviderConfigSource::ProviderConfigSource(
    provider_credential=Some(@oauth.ProviderCredential::OAuth(oauth_credential)),
  )
  let provider = KimiProvider()
  match @llm.ProviderFactory::build(provider, oauth_source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      assert_eq(slot.model_id, "k3-256k")
      assert_eq(slot.thinking_efforts, ["low", "high", "max"])
      assert_true(catalog.capabilities.contains("reasoning"))
    }
    _ => fail("expected a ready OAuth catalog")
  }
  // API-key credential without a model setting: platform default.
  let api_source = @llm.ProviderConfigSource::ProviderConfigSource(
    provider_credential=Some(
      @oauth.ProviderCredential::ApiKey(
        @oauth.ApiKeyCredential::ApiKeyCredential(secret="sk-x"),
      ),
    ),
  )
  match @llm.ProviderFactory::build(provider, api_source) {
    @llm.ProviderBuildResult::Ready(catalog) =>
      assert_eq(catalog.slots()[0].model_id, "kimi-k3")
    _ => fail("expected a ready API-key catalog")
  }
}

///|
/// Request shape snapshots — the kimi Responses contract.

///|
test "responses_request_lifts_system_messages_into_instructions" {
  let messages = [
    system_msg("be terse"),
    system_msg("answer in kind"),
    user_msg("hi"),
    assistant_msg("hello"),
  ]
  let body = build_responses_request(
    messages,
    [],
    chat_options(),
    "kimi-k3",
    false,
    None,
  )
  guard body is Object(root) else { fail("expected object") }
  assert_json_field_string(root, "instructions", "be terse\n\nanswer in kind")
  guard root.get("input") is Some(Array(items)) else { fail("input array") }
  assert_eq(items.length(), 2)
  for item in items {
    guard item is Object(obj) else { fail("input item object") }
    match obj.get("role") {
      Some(String("system")) => fail("system message leaked into input")
      _ => ()
    }
  }
}

///|
test "responses_request_omits_instructions_when_no_system_message" {
  let body = build_responses_request(
    [user_msg("hi")],
    [],
    chat_options(),
    "kimi-k3",
    false,
    None,
  )
  guard body is Object(root) else { fail("expected object") }
  match root.get("instructions") {
    None => ()
    Some(_) => fail("instructions must be absent without a system message")
  }
}

///|
test "responses_request_tools_array_is_kernel_functions_only" {
  let body = build_responses_request(
    [user_msg("hi")],
    [tool_def("read_file"), tool_def("write_file")],
    chat_options(),
    "kimi-k3",
    false,
    None,
    reasoning_effort=Some("high"),
  )
  guard body is Object(root) else { fail("expected object") }
  guard root.get("tools") is Some(Array(tools)) else { fail("tools array") }
  // The tools array is exactly the kernel function definitions — nothing
  // appended, no hosted-tool entries.
  assert_eq(tools.length(), 2)
  for tool in tools {
    guard tool is Object(entry) else { fail("tool object") }
    assert_json_field_string(entry, "type", "function")
    match entry.get("function") {
      None => ()
      Some(_) => fail("chat-wire nested function object must not appear")
    }
  }
  match tools[0] {
    Object(fn0) => assert_json_field_string(fn0, "name", "read_file")
    _ => fail("expected read_file first")
  }
  match root.get("include") {
    None => ()
    Some(_) => fail("include must never be emitted")
  }
  // reasoning.effort is the only reasoning knob.
  guard root.get("reasoning") is Some(Object(reasoning)) else {
    fail("expected reasoning object")
  }
  assert_json_field_string(reasoning, "effort", "high")
  match reasoning.get("summary") {
    None => ()
    Some(_) => fail("kimi must not request reasoning summaries")
  }
}

///|
test "responses_request_omits_tools_when_empty" {
  let body = build_responses_request(
    [user_msg("hi")],
    [],
    chat_options(),
    "kimi-k3",
    false,
    None,
  )
  guard body is Object(root) else { fail("expected object") }
  match root.get("tools") {
    None => ()
    Some(_) => fail("no tools may be emitted without function tools")
  }
}

///|
test "responses_request_maps_effort_tokens_cache_key_and_stream" {
  let body = build_responses_request(
    [user_msg("hi")],
    [],
    { temperature: Some(0.5), max_output_tokens: Some(256), },
    "kimi-k3",
    true,
    Some("posoco-session-42"),
    reasoning_effort=Some("low"),
  )
  guard body is Object(root) else { fail("expected object") }
  assert_json_field_string(root, "model", "kimi-k3")
  assert_json_field_number(root, "max_output_tokens", 256.0)
  assert_json_field_string(root, "prompt_cache_key", "posoco-session-42")
  match root.get("stream") {
    Some(Json::True) => ()
    _ => fail("stream must be true on the streaming body")
  }
  guard root.get("reasoning") is Some(Object(reasoning)) else {
    fail("expected reasoning object")
  }
  assert_json_field_string(reasoning, "effort", "low")
  match root.get("temperature") {
    None => ()
    Some(_) => fail("temperature must never be serialized")
  }
}

///|
test "responses_request_empty_effort_suppresses_reasoning_field" {
  // A refresh that has not resolved the catalog effort list yet passes ""
  // through config; the wire must not carry an empty effort.
  let body = build_responses_request(
    [user_msg("hi")],
    [],
    chat_options(),
    "kimi-k3",
    false,
    None,
    reasoning_effort=Some(""),
  )
  guard body is Object(root) else { fail("expected object") }
  match root.get("reasoning") {
    None => ()
    Some(_) => fail("empty effort must suppress the reasoning field")
  }
}

///|
/// Forbidden-param guard: even when ChatOptions carries sampling knobs, the
/// serialized body never names a parameter the Kimi Responses wire rejects.
test "responses_request_never_serializes_forbidden_params" {
  let body = build_responses_request(
    [system_msg("be terse"), user_msg("hello")],
    [tool_def("read_file")],
    { temperature: Some(0.7), max_output_tokens: Some(256), },
    "kimi-k3",
    true,
    Some("posoco-session-42"),
    reasoning_effort=Some("high"),
  )
  let text = body.stringify()
  for
    forbidden in [
      "temperature", "top_p", "tool_choice", "search_context_size", "blocked_domains",
      "store", "previous_response_id", "max_completion_tokens", "thinking",
    ] {
    assert_false(text.contains(forbidden))
  }
}

///|
/// Tool-call-id sanitization keeps replay correlation inside the charset
/// kimi accepts, on both function_call and function_call_output items.
test "input_items_sanitize_call_ids_on_replay" {
  let assistant : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[],
    tool_calls=[
      {
        call_id: @posoco.CallId::unchecked("call:42|/x"),
        name: @posoco.ToolName::unchecked("read"),
        arguments: Json::empty_object(),
      },
    ],
    reasoning=None,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let tool_result : @posoco.Message = @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call:42|/x"),
    tool_name=@posoco.ToolName::unchecked("read"),
    outcome=@posoco.ToolOutcome::Success(
      content="file contents",
      structured=None,
    ),
  )
  let items = kimi_input_items([assistant, tool_result])
  assert_eq(items.length(), 2)
  guard items[0] is Object(call_item) else { fail("function_call item") }
  match call_item.get("type") {
    Some(String("function_call")) => ()
    _ => fail("expected function_call item")
  }
  assert_json_field_string(call_item, "call_id", "call_42__x")
  guard items[1] is Object(output_item) else { fail("function_call_output") }
  match output_item.get("type") {
    Some(String("function_call_output")) => ()
    _ => fail("expected function_call_output item")
  }
  assert_json_field_string(output_item, "call_id", "call_42__x")
}

///|
/// Reasoning: the reasoning item rides Reasoning.raw for verbatim replay.
fn reasoning_fixture() -> Json {
  {
    "status": "completed",
    "output": [
      {
        "type": "reasoning",
        "id": "rs_1",
        "summary": [{ "type": "summary_text", "text": "weighing sources" }],
      },
      {
        "type": "message",
        "role": "assistant",
        "content": [{ "type": "output_text", "text": "here is the answer" }],
      },
    ],
    "usage": {
      "input_tokens": 100,
      "output_tokens": 20,
      "total_tokens": 120,
      "input_tokens_details": { "cached_tokens": 80 },
      "cache_write_tokens": 7,
    },
  }
}

///|
test "decode_preserves_reasoning_raw_items_for_replay" {
  let completion = decode_responses_response(reasoning_fixture())
  guard completion.message.reasoning is Some(reasoning) else {
    fail("expected reasoning")
  }
  guard reasoning.raw is Some(Array(raw_items)) else {
    fail("expected raw reasoning items")
  }
  assert_eq(raw_items.length(), 1)
  guard raw_items[0] is Object(reasoning_item) else { fail("reasoning raw") }
  match reasoning_item.get("type") {
    Some(String("reasoning")) => ()
    _ => fail("expected reasoning raw item")
  }
  assert_eq(reasoning.content, "weighing sources")
  // Usage: kimi Responses field names; cache_write_tokens ignored for
  // cached accounting.
  match completion.usage {
    Some(usage) => {
      assert_eq(usage.input_tokens, Some(100))
      assert_eq(usage.output_tokens, Some(20))
      assert_eq(usage.total_tokens, Some(120))
      assert_eq(usage.cached_input_tokens, Some(80))
    }
    None => fail("expected usage")
  }
}

///|
test "decode_without_search_keeps_plain_answer" {
  let fixture : Json = {
    "status": "completed",
    "output": [
      {
        "type": "message",
        "role": "assistant",
        "content": [{ "type": "output_text", "text": "plain answer" }],
      },
    ],
  }
  let completion = decode_responses_response(fixture)
  match completion.message.content[0] {
    Text(t) => assert_eq(t, "plain answer")
    _ => fail("expected text content")
  }
}

///|
/// Replay round-trip: a completion carrying reasoning raw items re-encodes
/// verbatim into the next request's input.
test "replay_round_trip_reemits_raw_items_verbatim" {
  let completion = decode_responses_response(reasoning_fixture())
  let assistant : @posoco.Message = @posoco.Message::AssistantMessage(
    content=completion.message.content,
    tool_calls=completion.message.tool_calls,
    reasoning=completion.message.reasoning,
    finish_reason=completion.message.finish_reason,
  )
  let items = kimi_input_items([user_msg("think then answer"), assistant])
  // items: user message, then the reasoning raw item (the kit collects
  // reasoning items), then the assistant message item.
  assert_eq(items.length(), 3)
  guard items[1] is Object(reasoning_item) else { fail("reasoning replay") }
  match reasoning_item.get("id") {
    Some(String("rs_1")) => ()
    _ => fail("expected verbatim reasoning replay")
  }
  match reasoning_item.get("type") {
    Some(String("reasoning")) => ()
    _ => fail("expected the reasoning item verbatim")
  }
  guard items[2] is Object(message_item) else { fail("message replay") }
  assert_json_field_string(message_item, "role", "assistant")
}

///|
/// Length truncation: incomplete + max_output_tokens is a Length finish,
/// not a protocol failure; an unexplained incomplete stays loud.
test "decode_maps_max_output_tokens_truncation_to_length" {
  let fixture : Json = {
    "status": "incomplete",
    "status_details": { "reason": "max_output_tokens" },
    "output": [
      {
        "type": "message",
        "role": "assistant",
        "content": [{ "type": "output_text", "text": "partial answer" }],
      },
    ],
  }
  let completion = decode_responses_response(fixture)
  assert_true(completion.finish_reason() is @posoco.FinishReason::Length)
  match completion.message.content[0] {
    Text(t) => assert_eq(t, "partial answer")
    _ => fail("partial content must survive")
  }
}

///|
test "decode_keeps_unexplained_incomplete_loud" {
  let fixture : Json = { "status": "incomplete", "output": [] }
  let result = Ok(decode_responses_response(fixture)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("not_completed"))
    _ => fail("an unexplained incomplete must stay a parse failure")
  }
}

///|
test "decode_malformed_tool_arguments_are_loud_and_redacted" {
  let fixture : Json = {
    "status": "completed",
    "output": [
      {
        "type": "function_call",
        "call_id": "call_1",
        "name": "bad",
        "arguments": "not-valid-json-secret",
      },
    ],
  }
  let result = Ok(decode_responses_response(fixture)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("stage=tool.arguments_json"))
      assert_true(message.contains("payload_chars="))
      assert_false(message.contains("not-valid-json-secret"))
    }
    _ => fail("expected redacted ResponseParse for malformed arguments")
  }
}

///|
/// Streaming: fixtures from the documented event vocabulary, delegated to
/// the shared kit exactly like the production loop does (kit owns
/// accumulation and pushes every chunk exactly once).

///|
fn sse_run(
  events : Array[String],
) -> (
  @posoco.StreamAccumulator,
  Array[@posoco.StreamChunk],
  @responses.SseStreamState,
  Bool,
) raise {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let forwarded : Array[@posoco.StreamChunk] = []
  let state = @responses.SseStreamState::SseStreamState()
  let mut done = false
  for event in events {
    done = @responses.process_responses_sse(
      provider="kimi",
      event,
      acc,
      fn(chunk) { forwarded.push(chunk) },
      state~,
    )
  }
  (acc, forwarded, state, done)
}

///|
test "sse_happy_path_streams_text_reasoning_tools_and_usage" {
  let ev_created =
    #|{"type":"response.created","response":{"id":"resp_1"}}
  let ev_fc_added =
    #|{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":""}}
  let ev_args_delta_1 =
    #|{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"path\""}
  let ev_args_delta_2 =
    #|{"type":"response.function_call_arguments.delta","output_index":1,"delta":":\"/tmp/x\"}"}
  let ev_reasoning_added =
    #|{"type":"response.output_item.added","output_index":2,"item":{"type":"reasoning","id":"rs_1","summary":[]}}
  let ev_reasoning_delta =
    #|{"type":"response.reasoning_summary_text.delta","delta":"thinking"}
  let ev_text_delta =
    #|{"type":"response.output_text.delta","delta":"hello"}
  let ev_reasoning_done =
    #|{"type":"response.output_item.done","output_index":2,"item":{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"thinking"}],"encrypted_content":"enc-payload"}}
  let ev_completed =
    #|{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15,"input_tokens_details":{"cached_tokens":4}}}}
  let events = [
    ev_created, ev_fc_added, ev_args_delta_1, ev_args_delta_2, ev_reasoning_added,
    ev_reasoning_delta, ev_text_delta, ev_reasoning_done, ev_completed,
  ]
  let (acc, forwarded, state, done) = sse_run(events)
  assert_true(done)
  // Forwarded chunk order: call identity, argument deltas, reasoning,
  // text, usage, finish. Each forwarded exactly once (no double push).
  assert_eq(forwarded.length(), 7)
  guard forwarded[0]
    is @posoco.StreamChunk::ToolCallDelta(
      index=0,
      id=Some("call_1"),
      name=Some("read_file"),
      arguments_delta=None
    ) else {
    fail("expected tool call identity chunk (wire index 1 remapped to slot 0)")
  }
  guard forwarded[1]
    is @posoco.StreamChunk::ToolCallDelta(arguments_delta=Some("{\"path\""), ..) else {
    fail("expected first argument delta")
  }
  guard forwarded[2]
    is @posoco.StreamChunk::ToolCallDelta(
      arguments_delta=Some(":\"/tmp/x\"}"),
      ..
    ) else {
    fail("expected second argument delta")
  }
  guard forwarded[3] is @posoco.StreamChunk::ReasoningDelta(token="thinking") else {
    fail("expected reasoning delta")
  }
  guard forwarded[4] is @posoco.StreamChunk::TextDelta(token="hello") else {
    fail("expected text delta")
  }
  guard forwarded[5]
    is @posoco.StreamChunk::Usage(
      input_tokens=10,
      output_tokens=5,
      total_tokens=15,
      cached_input_tokens=Some(4),
      ..
    ) else {
    fail("expected usage chunk")
  }
  guard forwarded[6] is @posoco.StreamChunk::Finish(reason="tool_calls") else {
    fail("expected finish chunk")
  }
  assert_eq(acc.text(), "hello")
  assert_eq(acc.reasoning(), "thinking")
  // The assembled completion, mirroring the production attach order.
  let completion = attach_kimi_stream_reasoning(
    @responses.responses_stream_completion(provider="kimi", acc),
    state,
  )
  let tcs = completion.tool_calls()
  assert_eq(tcs.length(), 1)
  assert_eq(tcs[0].call_id.to_string(), "call_1")
  assert_eq(tcs[0].name.to_string(), "read_file")
  guard tcs[0].arguments is Object(args) else { fail("arguments object") }
  match args.get("path") {
    Some(String(path)) => assert_eq(path, "/tmp/x")
    _ => fail("expected assembled path argument")
  }
  // Reasoning raw: the full reasoning item.
  guard completion.message.reasoning is Some(reasoning) else {
    fail("expected reasoning")
  }
  guard reasoning.raw is Some(Array(raw_items)) else {
    fail("expected raw items")
  }
  assert_eq(raw_items.length(), 1)
  match completion.usage {
    Some(usage) => {
      assert_eq(usage.input_tokens, Some(10))
      assert_eq(usage.cached_input_tokens, Some(4))
    }
    None => fail("expected usage on the completion")
  }
}

///|
test "sse_no_double_push_with_forwarding_callback" {
  // Production-style callback: forward the chunk to the host ONLY. The kit
  // parser owns accumulation; if either side pushed twice, the text would
  // double.
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let forwarded : Array[@posoco.StreamChunk] = []
  let on_chunk = fn(c : @posoco.StreamChunk) { forwarded.push(c) }
  let text_event =
    #|{"type":"response.output_text.delta","delta":"早上好"}
  let reasoning_event =
    #|{"type":"response.reasoning_summary_text.delta","delta":"思考中"}
  let _ = @responses.process_responses_sse(
    provider="kimi",
    text_event,
    acc,
    on_chunk,
  )
  let _ = @responses.process_responses_sse(
    provider="kimi",
    reasoning_event,
    acc,
    on_chunk,
  )
  assert_eq(forwarded.length(), 2)
  assert_eq(acc.text(), "早上好")
  assert_eq(acc.reasoning(), "思考中")
}

///|
test "sse_mid_stream_provider_error_is_transport_and_redacted" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let result = Ok(
    @responses.process_responses_sse(
      provider="kimi",
      "{\"error\":{\"code\":\"server_error\",\"type\":\"server_error\"}}",
      acc,
      fn(_) { () },
    ),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::Transport(message)) => {
      assert_true(message.contains("stage=error, category=provider_error"))
      assert_false(message.contains("secret"))
    }
    _ => fail("expected a mid-stream provider error to raise Transport")
  }
  let failed = Ok(
    @responses.process_responses_sse(
      provider="kimi",
      "{\"type\":\"response.failed\"}",
      acc,
      fn(_) { () },
    ),
  ) catch {
    e => Err(e)
  }
  match failed {
    Err(@posoco.ModelError::Transport(message)) =>
      assert_true(message.contains("stage=response.failed"))
    _ => fail("expected response.failed to raise Transport")
  }
}

///|
test "sse_malformed_payload_is_loud_and_redacted" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let secret = "secret-sse-payload"
  let result = Ok(
    @responses.process_responses_sse(provider="kimi", secret, acc, fn(_) { () }),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("stage=json"))
      assert_false(message.contains(secret))
    }
    _ => fail("expected ResponseParse for malformed SSE JSON")
  }
}

///|
test "stream_tool_argument_error_is_redacted_via_kit" {
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
  let result = Ok(@responses.validate_stream_tool_calls(provider="kimi", acc)) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("kimi SSE parse failure (stage=tool_calls)"))
      assert_false(message.contains(secret))
    }
    _ => fail("expected redacted stream argument error")
  }
}

///|
test "stream_termination_is_protocol_driven_via_kit" {
  assert_true(
    @responses.classify_stream_termination(
      provider="kimi",
      @responses.StreamTermination::ExplicitTerminal,
    )
    is None,
  )
  match
    @responses.classify_stream_termination(
      provider="kimi",
      @responses.StreamTermination::CleanEof,
    ) {
    Some(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("terminal_marker=missing"))
    _ => fail("clean EOF before the terminal marker must be ResponseParse")
  }
}

///|
/// prompt_cache_key: derived by default, opt-out, and rejection learning.

///|
test "prompt_cache_key_default_on_sends_derived_key" {
  let port = KimiModelPort(KimiConfig("key"))
  assert_true(port.config.send_prompt_cache_key)
  let cache_key = port.prompt_cache_key_for("session-42")
  guard cache_key is Some(key) else {
    fail("default config must derive a cache key")
  }
  assert_eq(key, "posoco-session-42")
  let body = build_responses_request(
    [user_msg("hi")],
    [],
    chat_options(),
    "kimi-k3",
    false,
    cache_key,
  )
  guard body is Object(root) else { fail("expected object") }
  assert_json_field_string(root, "prompt_cache_key", "posoco-session-42")
}

///|
test "prompt_cache_key_opt_out_omits_field" {
  let port = KimiModelPort(KimiConfig("key", send_prompt_cache_key=false))
  let cache_key = port.prompt_cache_key_for("session-42")
  guard cache_key is None else { fail("opt-out must not derive a cache key") }
  let body = build_responses_request(
    [user_msg("hi")],
    [],
    chat_options(),
    "kimi-k3",
    false,
    cache_key,
  )
  guard body is Object(root) else { fail("expected object") }
  match root.get("prompt_cache_key") {
    None => ()
    Some(_) => fail("opted-out request must omit prompt_cache_key")
  }
}

///|
test "prompt_cache_key_rejection_flag_omits_key_even_when_enabled" {
  let port = KimiModelPort(KimiConfig("key"))
  port.prompt_cache_key_rejected = true
  match port.prompt_cache_key_for("session-42") {
    None => ()
    Some(_) => fail("rejected cache key must be omitted even when enabled")
  }
}

///|
test "prompt_cache_key_rejection_body_sets_flag" {
  let port = KimiModelPort(KimiConfig("key"))
  port.learn_prompt_cache_key_rejection(
    "{\"error\":{\"message\":\"Unsupported parameter: 'prompt_cache_key' is not supported with this model.\"}}",
  )
  assert_true(port.prompt_cache_key_rejected)
  match port.prompt_cache_key_for("session-42") {
    None => ()
    Some(_) => fail("learned rejection must suppress the cache key")
  }
}

///|
test "prompt_cache_key_unrelated_400_body_does_not_set_flag" {
  let port = KimiModelPort(KimiConfig("key"))
  port.learn_prompt_cache_key_rejection(
    "{\"error\":{\"message\":\"Unsupported parameter: 'temperature' is not supported with this model.\"}}",
  )
  assert_true(!port.prompt_cache_key_rejected)
  match port.prompt_cache_key_for("session-42") {
    Some(_) => ()
    None => fail("unrelated 400 must not disable the cache key")
  }
}

///|
/// Model discovery: parser unchanged, catalog filtered to the k3-era
/// allowlist.

///|
test "kimi_models_parser_prefers_nested_effort_declaration" {
  let payload : Json = {
    "data": [
      {
        "id": "kimi-k3",
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
        "id": "k3",
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
      { "id": "k3-256k", "context_length": 8192, "supports_reasoning": true },
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
    "data": [{ "id": "k3", "context_length": 8192, "default_effort": "high" }],
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
test "catalog_filters_dropped_discovery_ids" {
  let payload : Json = {
    "data": [
      {
        "id": "kimi-k3",
        "context_length": 1000000,
        "think_efforts": {
          "support": true,
          "valid_efforts": ["low", "high", "max"],
          "default_effort": "high",
        },
      },
      {
        "id": "kimi-k2.6",
        "context_length": 262144,
        "think_efforts": {
          "support": true,
          "valid_efforts": ["low", "high", "max"],
          "default_effort": "high",
        },
      },
      { "id": "moonshot-v1-8k", "context_length": 8192 },
      {
        "id": "k3-256k",
        "context_length": 262144,
        "think_efforts": {
          "support": true,
          "valid_efforts": ["low", "high", "max"],
          "default_effort": "high",
        },
      },
    ],
  }
  let models = parse_kimi_models(payload)
  let port = KimiModelPort(KimiConfig("key"))
  let catalog = port.model_catalog_from_models(models)
  let slots = catalog.slots()
  // k2.x and moonshot-v1 entries never become slots; the configured model
  // stays first.
  assert_eq(slots.length(), 2)
  assert_eq(slots[0].model_id, "kimi-k3")
  assert_eq(slots[1].model_id, "k3-256k")
  assert_true(catalog.capabilities.contains("reasoning"))
}

///|
test "catalog_filters_refuse_an_all_dropped_discovery" {
  let payload : Json = {
    "data": [{ "id": "kimi-k2.6", "context_length": 262144 }],
  }
  let models = parse_kimi_models(payload)
  let port = KimiModelPort(KimiConfig("key"))
  let result = Ok(port.model_catalog_from_models(models)) catch { e => Err(e) }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("empty catalog"))
    _ => fail("expected an empty-catalog composition failure")
  }
}

///|
test "kimi_dynamic_slot_rebuild_preserves_catalog_metadata" {
  let config = KimiConfig(
    "key",
    model="kimi-k3",
    thinking_efforts=Some(["low", "high"]),
  )
  let port = KimiModelPort(config)
  let info = KimiModelInfo::{
    id: "kimi-k3",
    display_name: "Kimi K3",
    context_window: 131072,
    thinking_efforts: ["low", "high"],
    default_effort: Some("high"),
    capabilities: ["chat", "streaming", "reasoning"],
  }
  let other = KimiModelInfo::{
    id: "k3-256k",
    display_name: "Kimi K3 256k",
    context_window: 262144,
    thinking_efforts: ["high"],
    default_effort: Some("high"),
    capabilities: ["chat", "streaming", "reasoning"],
  }
  let catalog = port.model_catalog_from_models([other, info])
  let slot = catalog.slots()[0]
  assert_eq(slot.model_id, "kimi-k3")
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
    model="kimi-k3",
    reasoning_effort="",
    thinking_efforts=Some([]),
  )
  let port = KimiModelPort(config)
  let info = KimiModelInfo::{
    id: "kimi-k3",
    display_name: "Kimi K3",
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
test "with_reasoning_effort_rejects_undeclared_effort_at_config_boundary" {
  let config = KimiConfig("key", model="kimi-k3")
  assert_eq(config.with_reasoning_effort("max").reasoning_effort, "max")
  let invalid = Ok(config.with_reasoning_effort("ultra")) catch {
    err => Err(err)
  }
  match invalid {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("unsupported reasoning effort"))
    _ => fail("an undeclared effort must fail at the config boundary")
  }
}

///|
/// HTTP error classification for the Responses endpoints.

///|
test "http_error_formatter_is_payload_free" {
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
test "http_status_classifier_preserves_status_and_redacts_body" {
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
test "401_classifies_as_cross_host_credential_mismatch" {
  let err = classify_kimi_http_status(
    "chat.http_status",
    401,
    BodyBytesUtf8(38),
    body_text="{\"error\":{\"message\":\"Invalid API key\"}}",
    now_ms=0L,
  )
  guard err is Some(@posoco.ModelError::Transport(reason)) else {
    fail("expected Transport for 401")
  }
  assert_true(reason.contains("status=401"))
  assert_true(reason.contains("not interchangeable"))
  // The provider body text never rides the message.
  assert_false(reason.contains("Invalid API key"))
}

///|
test "400_coding_message_size_limit_is_named_loudly" {
  let body = "{\"error\":{\"message\":\"total message size 3000000 exceeds limit 2097152\"}}"
  let err = classify_kimi_http_status(
    "chat.http_status",
    400,
    BodyBytesUtf8(body.length()),
    body_text=body,
    now_ms=0L,
  )
  guard err is Some(@posoco.ModelError::Transport(reason)) else {
    fail("expected Transport for the 2 MiB rejection")
  }
  assert_true(reason.contains("2 MiB"))
  assert_true(reason.contains("2097152"))
  assert_false(reason.contains("3000000"))
  // An unrelated 400 keeps the generic redacted classification.
  let generic = classify_kimi_http_status(
    "chat.http_status",
    400,
    BodyBytesUtf8(9),
    body_text="{\"ok\":false}",
    now_ms=0L,
  )
  guard generic is Some(@posoco.ModelError::Transport(reason)) else {
    fail("expected Transport for generic 400")
  }
  assert_false(reason.contains("2 MiB"))
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
  // No Retry-After: the schedule falls back to the 5-hour window length.
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
/// Identity headers (unchanged contract with the coding host).

///|
/// Canned identity so header tests never probe the real host (the native
/// face runs uname + `sw_vers` via popen; see KimiIdentity).
fn kimi_test_identity() -> KimiIdentity {
  KimiIdentity::{
    hostname: "test-host",
    device_model: "test-model",
    os_version: "test-os",
  }
}

///|
test "kimi_default_headers mirrors kimi-code-cli identity set" {
  let headers = kimi_default_headers(
    device_id="11111111-1111-4111-8111-111111111111",
    identity=Some(kimi_test_identity()),
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
  assert_eq(headers["User-Agent"], "kimi-code-cli/1.2.3")
  assert_eq(headers["X-Msh-Platform"], "kimi_code_cli")
  assert_eq(headers["X-Msh-Device-Id"], "11111111-1111-4111-8111-111111111111")
  assert_eq(headers["X-Msh-Device-Name"], "test-host")
}

///|
test "kimi_default_headers mints a fallback device id when none supplied" {
  let headers_a = kimi_default_headers(identity=Some(kimi_test_identity()))
  let headers_b = kimi_default_headers(identity=Some(kimi_test_identity()))
  let a = headers_a["X-Msh-Device-Id"]
  let b = headers_b["X-Msh-Device-Id"]
  assert_true(a.length() > 0)
  assert_true(b.length() > 0)
  assert_true(a != b)
}

///|
/// KIMI_LIVE=1 opts into probing the real host identity externs (native:
/// uname + sw_vers via popen); default runs skip.
test "kimi_live_default_headers_probe_the_real_host" {
  if @env.get_env_var("KIMI_LIVE") != Some("1") {
    return
  }
  let headers = kimi_default_headers()
  assert_eq(headers["User-Agent"], "kimi-code-cli/1.2.3")
  assert_true(headers["X-Msh-Device-Name"].length() > 0)
  assert_true(headers["X-Msh-Device-Model"].length() > 0)
  assert_true(headers["X-Msh-Os-Version"].length() > 0)
}

///|
/// Compact: split/summary helpers (the network call reuses the chat
/// transport and is exercised end-to-end by hosts).

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

///|
test "compact_request_is_instructions_plus_input_without_tools" {
  // The summary prompt is [SystemMessage, UserMessage]; the Responses
  // encode lifts the system part into instructions and carries no tools
  // and no reasoning override.
  let prompt = @compact_summary.build_summary_prompt(
    @compact_summary.SummaryTemplate::KimiXml,
    "the transcript",
  )
  assert_eq(prompt.length(), 2)
  let body = build_responses_request(
    prompt,
    [],
    { temperature: None, max_output_tokens: None, },
    "kimi-k3",
    false,
    None,
    reasoning_effort=None,
  )
  guard body is Object(root) else { fail("expected object") }
  match root.get("instructions") {
    Some(String(instructions)) =>
      assert_true(instructions.contains("context compaction engine"))
    _ => fail("expected the summary system prompt as instructions")
  }
  guard root.get("input") is Some(Array(items)) else {
    fail("expected the input array")
  }
  assert_eq(items.length(), 1)
  guard items[0] is Object(user_item) else { fail("user item object") }
  match user_item.get("role") {
    Some(String("user")) => ()
    _ => fail("expected the conversation user item")
  }
  for absent in ["tools", "reasoning", "prompt_cache_key", "stream"] {
    match root.get(absent) {
      None => ()
      Some(_) => fail("compact request must omit: " + absent)
    }
  }
}
