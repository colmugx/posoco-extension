///|
test "codex requests include the JWT account header" {
  let credential = @oauth.Credential::Credential(
    access_token=codex_test_access_token(),
    refresh_token="refresh",
    expires_at=3600,
    metadata=Map([("account_id", "acct-123")]),
  )
  let config = OpenAIConfig::from_codex_credential(credential, "gpt-5")
  let headers = build_headers(config, None, false)
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
pub extend CodexRecordingTransport with @posoco/ext-oauth.OAuthHttpTransport::{
  post,
  get,
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
pub extend CodexRecordingInteraction with @posoco/ext-oauth.AuthInteraction::{
  notify,
  is_cancelled,
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
  started_ports : Array[Int32]
  mut stop_count : Int32
}

///|
pub impl @oauth.CallbackServer for CodexFakeCallbackServer with fn start(
  self : CodexFakeCallbackServer,
  port : Int32,
) -> Unit raise @oauth.OAuthError {
  self.started_ports.push(port)
}

///|
pub extend CodexFakeCallbackServer with @posoco/ext-oauth.CallbackServer::{
  start,
  stop,
  wait_callback,
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
  let rest = input.exact_view(start~).to_owned()
  match rest.find("&") {
    Some(amp) => Some(rest.exact_view(end=amp).to_owned())
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
pub extend OpenAIModelsRecordingTransport with OpenAIModelsHttpTransport::{get}

///|
async test "codex refresh sends version and account headers and preserves efforts" {
  let transport_impl = OpenAIModelsRecordingTransport::{
    urls: [],
    headers: [],
    responses: [
      // 1: release discovery; 2: models; 3: best-effort usage probe.
      OpenAIModelsHttpResponse::{
        status: 200,
        body: codex_release_body("rust-v0.160.0"),
      },
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
      OpenAIModelsHttpResponse::{
        status: 200,
        body: "{\"rate_limit\":{\"primary_window\":{\"used_percent\":10.0,\"limit_window_seconds\":18000,\"reset_at\":1777936568}}}",
      },
    ],
  }
  let transport : &OpenAIModelsHttpTransport = transport_impl
  version_cache_with_fixture(directory => {
    let provider = OpenAIProvider(
      transport=Some(transport),
      cache_dir=Some(directory),
    )
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
  })
  // Discovery ran first, credential-free, and the catalog request carried the
  // freshly discovered version with the account header.
  assert_eq(transport_impl.urls[0], codex_release_discovery_url())
  assert_eq(
    transport_impl.urls[1],
    "https://chatgpt.com/backend-api/codex/models?client_version=0.160.0",
  )
  assert_eq(
    transport_impl.headers[1].get("Authorization"),
    Some("Bearer " + codex_test_access_token()),
  )
  assert_eq(
    transport_impl.headers[1].get("chatgpt-account-id"),
    Some("acct-123"),
  )
  // The refresh also probes the usage endpoint on the same transport so the
  // 5h/weekly snapshot starts populated without model traffic.
  assert_eq(
    transport_impl.urls[2],
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
    use_responses_lite: false,
  }
  let slot = port.model_catalog_from_codex_models([info]).slots()[0]
  assert_eq(slot.model_id, "gpt-5.2-codex")
  assert_eq(slot.context_window, Some(400000))
  // The discovery window crosses the ModelPort seam so the Agent sizes
  // auto-compact from the active model's own capacity.
  assert_eq(slot.port.provider_config().context_window, Some(400000))
}

///|
/// Minimal /models record for visibility-filter tests: only the auth-relevant
/// fields vary.
fn codex_visibility_fixture(
  slug : String,
  visibility : String,
  supported_in_api : Bool,
) -> CodexModelInfo {
  CodexModelInfo::{
    slug,
    display_name: slug,
    description: None,
    default_reasoning_level: None,
    supported_reasoning_levels: [],
    visibility,
    supported_in_api,
    priority: 0,
    context_window: None,
    use_responses_lite: false,
  }
}

///|
test "codex visibility filter mirrors codex filter_by_auth semantics" {
  let subscription = codex_visibility_fixture("gpt-6-codex", "list", false)
  let api_model = codex_visibility_fixture("gpt-4o", "list", true)
  let hidden = codex_visibility_fixture("gpt-internal", "hide", true)
  let models = [subscription, api_model, hidden]
  // ChatGPT auth: visibility "list" alone selects; supported_in_api does not
  // gate subscription models.
  assert_eq(
    preferred_codex_models(models, "gpt-6-codex", chatgpt_mode=true).map(fn(
      model,
    ) {
      model.slug
    }),
    ["gpt-6-codex", "gpt-4o"],
  )
  // API-key auth: supported_in_api is additionally required.
  assert_eq(
    preferred_codex_models(models, "gpt-4o", chatgpt_mode=false).map(fn(model) {
      model.slug
    }),
    ["gpt-4o"],
  )
}

///|
test "codex catalog keeps ChatGPT subscription models that are not API-usable" {
  let config = OpenAIConfig::with_base_url(
    "sk-test", "gpt-6-codex", "https://example.com/v1",
  )
  let port = OpenAIModelPort(config)
  let info = codex_visibility_fixture("gpt-6-codex", "list", false)
  let slots = port.model_catalog_from_codex_models([info]).slots()
  assert_eq(slots.length(), 1)
  assert_eq(slots[0].model_id, "gpt-6-codex")
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
  let headers = build_headers(config, Some("sess-1"), true)
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
  let replayed = build_headers(config, Some("sess-1"), true)
  assert_eq(replayed.get("session-id"), Some("sess-1"))
  match (headers.get("thread-id"), replayed.get("thread-id")) {
    (Some(first), Some(second)) => assert_eq(first, second)
    _ => fail("thread-id must be stable within a session")
  }
  let other = build_headers(config, Some("sess-2"), true)
  match (headers.get("thread-id"), other.get("thread-id")) {
    (Some(first), Some(second)) => assert_true(first != second)
    _ => fail("different sessions must derive different thread ids")
  }
}

///|
test "api key base url gets the user agent but no codex protocol headers" {
  let config = OpenAIConfig::with_base_url(
    "sk-test", "gpt-5", "https://api.openai.com/v1",
  )
  let headers = build_headers(config, Some("sess-3"), true)
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
/// The port comes from a transient listener bound to 0 (kernel picks a free
/// one) that is closed before dialing, so no fixed discard port is needed:
/// URL resolution must succeed and only the TCP connect may fail — never
/// stage=create_client InvalidFormat.
async test "openai path-bearing base_url connects to the origin" {
  let probe_server = @socket.TcpServer(
    @socket.Addr::resolve("127.0.0.1", port=0),
  ) catch {
    _ => fail("could not bind a loopback probe listener")
  }
  let port = probe_server.addr.port()
  probe_server.close()
  let config = OpenAIConfig::with_base_url(
    "k",
    "gpt-5",
    "https://127.0.0.1:\{port}/v1",
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
/// Load-time renewal fakes and tests. The models transport replays scripted
/// responses; the OAuth transport captures refresh-grant posts.

///|
fn load_refresh_models_body() -> String {
  "{\"models\":[{\"slug\":\"gpt-codex\",\"display_name\":\"GPT Codex\"," +
  "\"default_reasoning_level\":\"medium\",\"supported_reasoning_levels\":[" +
  "{\"effort\":\"medium\",\"description\":\"balanced\"}]," +
  "\"visibility\":\"list\",\"supported_in_api\":true,\"priority\":1," +
  "\"context_window\":272000}]}"
}

///|
fn load_refresh_usage_body() -> String {
  "{\"rate_limit\":{\"primary_window\":{\"used_percent\":10.0," +
  "\"limit_window_seconds\":18000,\"reset_at\":1777936568}}}"
}

///|
fn codex_renewal_response_body() -> String {
  "{\"access_token\":\"" +
  codex_renewed_access_token() +
  "\",\"refresh_token\":\"rotated\",\"expires_in\":3600,\"token_type\":\"Bearer\"}"
}

///|
/// Same JWT payload (acct-123 claim) as `codex_test_access_token` with a
/// distinct signature, so tests can tell the renewed bearer token apart.
fn codex_renewed_access_token() -> String {
  "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0xMjMifX0.renewed"
}

///|
struct LoadRefreshFailingStore {}

///|
pub impl @oauth.ProviderCredentialStore for LoadRefreshFailingStore with fn read(
  _self : LoadRefreshFailingStore,
  _provider_id : String,
) -> @oauth.ProviderCredential? {
  None
}

///|
pub impl @oauth.ProviderCredentialStore for LoadRefreshFailingStore with fn write(
  _self : LoadRefreshFailingStore,
  _provider_id : String,
  _credential : @oauth.ProviderCredential,
) -> Unit raise @oauth.OAuthError {
  raise @oauth.OAuthError::HttpError("write rejected")
}

///|
pub impl @oauth.ProviderCredentialStore for LoadRefreshFailingStore with fn delete(
  _self : LoadRefreshFailingStore,
  _provider_id : String,
) -> Unit raise @oauth.OAuthError {
  raise @oauth.OAuthError::HttpError("delete rejected")
}

///|
pub extend LoadRefreshFailingStore with @posoco/ext-oauth.ProviderCredentialStore::{
  read,
  write,
  delete,
}

///|
fn load_refresh_expired_credential() -> @oauth.Credential {
  @oauth.Credential::Credential(
    access_token=codex_test_access_token(),
    refresh_token="stale-refresh",
    expires_at=openai_now_epoch_secs() - 100,
    metadata=Map([("account_id", "acct-123")]),
  )
}

///|
async test "expired codex credential renews before the catalog fetch" {
  let models_transport_impl = OpenAIModelsRecordingTransport::{
    urls: [],
    headers: [],
    responses: [
      // 1: release discovery; 2: models; 3: best-effort usage probe.
      OpenAIModelsHttpResponse::{
        status: 200,
        body: codex_release_body("rust-v0.160.0"),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_models_body(),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_usage_body(),
      },
    ],
  }
  let models_transport : &OpenAIModelsHttpTransport = models_transport_impl
  let oauth_transport_impl = CodexRecordingTransport::{
    requests: [],
    responses: [
      @oauth.OAuthHttpResponse::{
        status: 200,
        body: codex_renewal_response_body(),
      },
    ],
  }
  let oauth_transport : &@oauth.OAuthHttpTransport = oauth_transport_impl
  let store = @oauth.InMemoryProviderCredentialStore::InMemoryProviderCredentialStore()
  version_cache_with_fixture(directory => {
    let provider = OpenAIProvider(
      transport=Some(models_transport),
      oauth_transport=Some(oauth_transport),
      cache_dir=Some(directory),
    )
    let source = @llm.ProviderConfigSource::ProviderConfigSource(
      settings=Some(@json.parse("{\"model\":\"gpt-codex\"}")),
      provider_credential=Some(
        @oauth.ProviderCredential::OAuth(load_refresh_expired_credential()),
      ),
      credential_store=Some(store),
    )
    match provider.refresh(source) {
      @llm.ProviderBuildResult::Ready(_) => ()
      @llm.ProviderBuildResult::Unconfigured =>
        fail("OAuth source was configured")
    }
  })
  // The refresh grant ran once, before any models request.
  assert_eq(oauth_transport_impl.requests.length(), 1)
  assert_true(
    oauth_transport_impl.requests[0].body.contains("grant_type=refresh_token"),
  )
  assert_eq(models_transport_impl.urls.length(), 3)
  assert_eq(
    models_transport_impl.headers[1].get("Authorization"),
    Some("Bearer " + codex_renewed_access_token()),
  )
  // The rotated record persists under the router provider id.
  match store.read("openai") {
    Some(@oauth.ProviderCredential::OAuth(stored)) =>
      assert_eq(stored.refresh_token, "rotated")
    _ => fail("renewed credential must persist")
  }
}

///|
async test "rejected codex access token renews once and retries the fetch" {
  let models_transport_impl = OpenAIModelsRecordingTransport::{
    urls: [],
    headers: [],
    responses: [
      // 1: release discovery; 2: first models call rejected; 3: retry;
      // 4: best-effort usage probe.
      OpenAIModelsHttpResponse::{
        status: 200,
        body: codex_release_body("rust-v0.160.0"),
      },
      OpenAIModelsHttpResponse::{
        status: 401,
        body: "{\"error\":\"expired\"}",
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_models_body(),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_usage_body(),
      },
    ],
  }
  let models_transport : &OpenAIModelsHttpTransport = models_transport_impl
  let oauth_transport_impl = CodexRecordingTransport::{
    requests: [],
    responses: [
      @oauth.OAuthHttpResponse::{
        status: 200,
        body: codex_renewal_response_body(),
      },
    ],
  }
  let oauth_transport : &@oauth.OAuthHttpTransport = oauth_transport_impl
  version_cache_with_fixture(directory => {
    let provider = OpenAIProvider(
      transport=Some(models_transport),
      oauth_transport=Some(oauth_transport),
      cache_dir=Some(directory),
    )
    let valid = @oauth.Credential::Credential(
      access_token=codex_test_access_token(),
      refresh_token="refresh",
      expires_at=0,
      metadata=Map([("account_id", "acct-123")]),
    )
    let source = @llm.ProviderConfigSource::ProviderConfigSource(
      settings=Some(@json.parse("{\"model\":\"gpt-codex\"}")),
      provider_credential=Some(@oauth.ProviderCredential::OAuth(valid)),
    )
    match provider.refresh(source) {
      @llm.ProviderBuildResult::Ready(_) => ()
      @llm.ProviderBuildResult::Unconfigured =>
        fail("OAuth source was configured")
    }
  })
  // No pre-renewal for a valid token; the 401 triggered exactly one renewal
  // and exactly one retry carrying the renewed bearer token. The usage probe
  // rides the same transport as the fourth GET.
  assert_eq(oauth_transport_impl.requests.length(), 1)
  assert_eq(models_transport_impl.urls.length(), 4)
  assert_eq(
    models_transport_impl.headers[1].get("Authorization"),
    Some("Bearer " + codex_test_access_token()),
  )
  assert_eq(
    models_transport_impl.headers[2].get("Authorization"),
    Some("Bearer " + codex_renewed_access_token()),
  )
}

///|
async test "rejected refresh_token surfaces the renewal error without a retry" {
  let models_transport_impl = OpenAIModelsRecordingTransport::{
    urls: [],
    headers: [],
    responses: [
      // 1: release discovery; 2: first models call rejected.
      OpenAIModelsHttpResponse::{
        status: 200,
        body: codex_release_body("rust-v0.160.0"),
      },
      OpenAIModelsHttpResponse::{
        status: 401,
        body: "{\"error\":\"expired\"}",
      },
    ],
  }
  let models_transport : &OpenAIModelsHttpTransport = models_transport_impl
  let oauth_transport_impl = CodexRecordingTransport::{
    requests: [],
    responses: [
      @oauth.OAuthHttpResponse::{
        status: 200,
        body: "{\"error\":\"invalid_grant\"}",
      },
    ],
  }
  let oauth_transport : &@oauth.OAuthHttpTransport = oauth_transport_impl
  version_cache_with_fixture(directory => {
    let provider = OpenAIProvider(
      transport=Some(models_transport),
      oauth_transport=Some(oauth_transport),
      cache_dir=Some(directory),
    )
    let valid = @oauth.Credential::Credential(
      access_token=codex_test_access_token(),
      refresh_token="revoked",
      expires_at=0,
      metadata=Map([("account_id", "acct-123")]),
    )
    let source = @llm.ProviderConfigSource::ProviderConfigSource(
      settings=Some(@json.parse("{\"model\":\"gpt-codex\"}")),
      provider_credential=Some(@oauth.ProviderCredential::OAuth(valid)),
    )
    try provider.refresh(source) catch {
      @posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~) => {
        assert_eq(manifest_id, "posoco_ext_openai")
        assert_true(detail.contains("invalid_grant"))
        // One renewal attempt, no models retry.
        assert_eq(oauth_transport_impl.requests.length(), 1)
        assert_eq(models_transport_impl.urls.length(), 2)
      }
      _ => fail("expected the typed renewal error")
    } noraise {
      _ => fail("expected the refresh to fail on invalid_grant")
    }
  })
}

///|
async test "renewal persists through a failing store and still serves slots" {
  let models_transport_impl = OpenAIModelsRecordingTransport::{
    urls: [],
    headers: [],
    responses: [
      // 1: release discovery; 2: first models call rejected; 3: retry;
      // 4: best-effort usage probe.
      OpenAIModelsHttpResponse::{
        status: 200,
        body: codex_release_body("rust-v0.160.0"),
      },
      OpenAIModelsHttpResponse::{
        status: 401,
        body: "{\"error\":\"expired\"}",
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_models_body(),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_usage_body(),
      },
    ],
  }
  let models_transport : &OpenAIModelsHttpTransport = models_transport_impl
  let oauth_transport_impl = CodexRecordingTransport::{
    requests: [],
    responses: [
      @oauth.OAuthHttpResponse::{
        status: 200,
        body: codex_renewal_response_body(),
      },
    ],
  }
  let oauth_transport : &@oauth.OAuthHttpTransport = oauth_transport_impl
  version_cache_with_fixture(directory => {
    let provider = OpenAIProvider(
      transport=Some(models_transport),
      oauth_transport=Some(oauth_transport),
      cache_dir=Some(directory),
    )
    let valid = @oauth.Credential::Credential(
      access_token=codex_test_access_token(),
      refresh_token="refresh",
      expires_at=0,
      metadata=Map([("account_id", "acct-123")]),
    )
    let source = @llm.ProviderConfigSource::ProviderConfigSource(
      settings=Some(@json.parse("{\"model\":\"gpt-codex\"}")),
      provider_credential=Some(@oauth.ProviderCredential::OAuth(valid)),
      credential_store=Some(LoadRefreshFailingStore::{ }),
    )
    match provider.refresh(source) {
      @llm.ProviderBuildResult::Ready(_) => ()
      @llm.ProviderBuildResult::Unconfigured =>
        fail("OAuth source was configured")
    }
  })
  // The renewed token still reached the retried request despite the failed
  // persistence.
  assert_eq(
    models_transport_impl.headers[2].get("Authorization"),
    Some("Bearer " + codex_renewed_access_token()),
  )
}

///|
async test "renewal-rejected access token after pre-renewal stops without a second renewal" {
  let models_transport_impl = OpenAIModelsRecordingTransport::{
    urls: [],
    headers: [],
    responses: [
      // 1: release discovery; 2: first models call rejected.
      OpenAIModelsHttpResponse::{
        status: 200,
        body: codex_release_body("rust-v0.160.0"),
      },
      OpenAIModelsHttpResponse::{
        status: 401,
        body: "{\"error\":\"expired\"}",
      },
    ],
  }
  let models_transport : &OpenAIModelsHttpTransport = models_transport_impl
  let oauth_transport_impl = CodexRecordingTransport::{
    requests: [],
    responses: [
      @oauth.OAuthHttpResponse::{
        status: 200,
        body: codex_renewal_response_body(),
      },
    ],
  }
  let oauth_transport : &@oauth.OAuthHttpTransport = oauth_transport_impl
  version_cache_with_fixture(directory => {
    let provider = OpenAIProvider(
      transport=Some(models_transport),
      oauth_transport=Some(oauth_transport),
      cache_dir=Some(directory),
    )
    let source = @llm.ProviderConfigSource::ProviderConfigSource(
      settings=Some(@json.parse("{\"model\":\"gpt-codex\"}")),
      provider_credential=Some(
        @oauth.ProviderCredential::OAuth(load_refresh_expired_credential()),
      ),
    )
    try provider.refresh(source) catch {
      @posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~) => {
        assert_eq(manifest_id, "posoco_ext_openai")
        assert_true(detail.contains("rejected after renewal"))
        assert_eq(oauth_transport_impl.requests.length(), 1)
        assert_eq(models_transport_impl.urls.length(), 2)
      }
      _ => fail("expected the post-renewal rejection error")
    } noraise {
      _ => fail("expected the refresh to fail after a renewed rejection")
    }
  })
}

///|
async test "valid credential with healthy catalog skips renewal entirely" {
  let models_transport_impl = OpenAIModelsRecordingTransport::{
    urls: [],
    headers: [],
    responses: [
      // 1: release discovery; 2: models; 3: best-effort usage probe.
      OpenAIModelsHttpResponse::{
        status: 200,
        body: codex_release_body("rust-v0.160.0"),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_models_body(),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_usage_body(),
      },
    ],
  }
  let models_transport : &OpenAIModelsHttpTransport = models_transport_impl
  let oauth_transport_impl = CodexRecordingTransport::{
    requests: [],
    responses: [],
  }
  let oauth_transport : &@oauth.OAuthHttpTransport = oauth_transport_impl
  version_cache_with_fixture(directory => {
    let provider = OpenAIProvider(
      transport=Some(models_transport),
      oauth_transport=Some(oauth_transport),
      cache_dir=Some(directory),
    )
    let valid = @oauth.Credential::Credential(
      access_token=codex_test_access_token(),
      refresh_token="refresh",
      expires_at=0,
      metadata=Map([("account_id", "acct-123")]),
    )
    let source = @llm.ProviderConfigSource::ProviderConfigSource(
      settings=Some(@json.parse("{\"model\":\"gpt-codex\"}")),
      provider_credential=Some(@oauth.ProviderCredential::OAuth(valid)),
    )
    match provider.refresh(source) {
      @llm.ProviderBuildResult::Ready(_) => ()
      @llm.ProviderBuildResult::Unconfigured =>
        fail("OAuth source was configured")
    }
  })
  assert_eq(oauth_transport_impl.requests.length(), 0)
  assert_eq(models_transport_impl.urls.length(), 3)
}

// ------------------------------------------------ offline cache expansion

///|
fn codex_test_source_with_cache(
  cache : String,
) -> @llm.ProviderConfigSource raise {
  let credential = @oauth.Credential::Credential(
    access_token=codex_test_access_token(),
    refresh_token="refresh",
    expires_at=0,
    metadata=Map([("account_id", "acct-123")]),
  )
  @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      @json.parse("{\"model\":\"gpt-codex\",\"reasoning_effort\":\"xhigh\"}"),
    ),
    provider_credential=Some(@oauth.ProviderCredential::OAuth(credential)),
    cached_models=Some(@json.parse(cache)),
  )
}

///|
test "build expands host-cached codex records into the multi-slot catalog offline" {
  let provider = OpenAIProvider()
  let cache = "[" +
    "{\"model_id\":\"gpt-codex\",\"thinking_efforts\":[\"low\",\"medium\",\"xhigh\"],\"default_effort\":\"medium\",\"context_window\":272000,\"image_in\":true}," +
    "{\"model_id\":\"gpt-next\",\"thinking_efforts\":[\"low\"],\"default_effort\":\"low\",\"context_window\":128000,\"image_in\":false}" +
    "]"
  match provider.build(codex_test_source_with_cache(cache)) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slots = catalog.slots()
      assert_eq(slots.length(), 2)
      // Cache order is preserved; slot ids keep the provider/model shape.
      assert_eq(slots[0].id, "openai/gpt-codex")
      assert_eq(slots[1].id, "openai/gpt-next")
      assert_eq(slots[0].thinking_efforts, ["low", "medium", "xhigh"])
      assert_eq(slots[0].default_effort, Some("medium"))
      assert_eq(slots[0].context_window, Some(272000))
      assert_true(slots[0].capabilities.contains("image_in"))
      assert_true(slots[1].context_window == Some(128000))
      assert_eq(catalog.capabilities, [
        "chat", "streaming", "oauth", "reasoning",
      ])
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("an OAuth source with a cache must build")
  }
}

///|
test "build keeps a persisted codex effort only while it is advertised" {
  let provider = OpenAIProvider()
  let cache = "[" +
    "{\"model_id\":\"gpt-codex\",\"thinking_efforts\":[\"low\"],\"default_effort\":\"low\",\"context_window\":null,\"image_in\":false}" +
    "]"
  match provider.build(codex_test_source_with_cache(cache)) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slots = catalog.slots()
      assert_eq(slots.length(), 1)
      assert_eq(slots[0].default_effort, Some("low"))
      assert_false(slots[0].capabilities.contains("image_in"))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("an OAuth source with a cache must build")
  }
}

///|
test "build expands host-cached api-key records without oauth" {
  let provider = OpenAIProvider()
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    provider_credential=Some(
      @oauth.ProviderCredential::ApiKey(
        @oauth.ApiKeyCredential::ApiKeyCredential(secret="sk-test"),
      ),
    ),
    cached_models=Some(
      @json.parse(
        "[{\"model_id\":\"gpt-a\",\"thinking_efforts\":[],\"default_effort\":null,\"context_window\":null,\"image_in\":false}]",
      ),
    ),
  )
  match provider.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slots = catalog.slots()
      assert_eq(slots.length(), 1)
      assert_eq(slots[0].id, "openai/gpt-a")
      assert_eq(catalog.capabilities, ["chat", "streaming", "api_key"])
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("an api-key source was configured")
  }
}

///|
test "a malformed cache degrades to the static single-model catalog" {
  let provider = OpenAIProvider()
  let source = codex_test_source_with_cache("[{\"broken\":true}]")
  match provider.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slots = catalog.slots()
      assert_eq(slots.length(), 1)
      assert_eq(slots[0].id, "openai/gpt-codex")
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("an OAuth source was configured")
  }
}

///|
test "an empty cache degrades to the static single-model catalog" {
  let provider = OpenAIProvider()
  let source = codex_test_source_with_cache("[]")
  match provider.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) =>
      assert_eq(catalog.slots().length(), 1)
    @llm.ProviderBuildResult::Unconfigured =>
      fail("an OAuth source was configured")
  }
}
