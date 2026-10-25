///|
/// White-box tests for the OpenCode Go plane: wire resolution against the
/// vendor's Go endpoints table, the `/usage` decode contract, the plan
/// allowance table, the rate-limit reset binding, and the factory settings
/// contract. Live transport is covered by the manual verification pass; the
/// parse/classification layer is fully offline here.

///|
fn go_base_config() -> @zen.OpenCodeZenConfig {
  @zen.OpenCodeZenConfig(
    "sk-go-test",
    base_url="https://opencode.ai/inference/go/v1",
    model="glm-5.3-flash",
    client_id="opencode-go",
    spend_source="posoco_ext_opencode_go",
  )
}

///|
/// Go shares OpenCode's wire implementation with Zen, but must supply its
/// own product identity and the calling agent's *conversation* identity.
/// Two Go agents in one process must never collapse into one gateway session.
test "Go gateway routing keeps independent per-agent session identity" {
  let first = @zen.opencode_request_headers("opencode-go", "go-agent-a")
  let next = @zen.opencode_request_headers("opencode-go", "go-agent-a")
  let other = @zen.opencode_request_headers("opencode-go", "go-agent-b")
  assert_eq(first["x-opencode-client"], "opencode-go")
  assert_eq(first["User-Agent"], "posoco/opencode-go")
  assert_eq(first["x-opencode-session"], "go-agent-a")
  assert_eq(next["x-opencode-session"], first["x-opencode-session"])
  assert_eq(other["x-opencode-session"], "go-agent-b")
  assert_true(first["x-opencode-session"] != other["x-opencode-session"])
  assert_true(first["x-opencode-request"] != next["x-opencode-request"])
}

///|
test "resolve_go_wire follows the vendor Go endpoints table" {
  // The Go-plane overrides where the family rule disagrees.
  assert_eq(resolve_go_wire("qwen3.8-max"), @zen.Messages)
  assert_eq(resolve_go_wire("qwen3.8-flash"), @zen.Messages)
  assert_eq(resolve_go_wire("minimax-m3"), @zen.Messages)
  assert_eq(resolve_go_wire("minimax-m2.7"), @zen.Messages)
  // Family rules carry the rest of the documented table.
  assert_eq(resolve_go_wire("gpt-6-luna"), @zen.Responses)
  assert_eq(resolve_go_wire("gpt-5.6-luna"), @zen.Responses)
  assert_eq(resolve_go_wire("grok-4.7"), @zen.Responses)
  assert_eq(resolve_go_wire("muse-spark-1.3-contributor"), @zen.Responses)
  assert_eq(resolve_go_wire("claude-haiku-5-5"), @zen.Messages)
  assert_eq(resolve_go_wire("glm-5.3-flash"), @zen.ChatCompletions)
  assert_eq(resolve_go_wire("kimi-k3"), @zen.ChatCompletions)
  assert_eq(resolve_go_wire("deepseek-v4.1-flash"), @zen.ChatCompletions)
  assert_eq(resolve_go_wire("longcat-2.0"), @zen.ChatCompletions)
  assert_eq(resolve_go_wire("hy3"), @zen.ChatCompletions)
  // Settings overrides win over the table.
  assert_eq(
    resolve_go_wire(
      "glm-5.3-flash",
      overrides=Map::from_array([("glm-5.3-flash", "responses")]),
    ),
    @zen.Responses,
  )
  // Unknown ids land on the gateway default.
  assert_eq(resolve_go_wire("omen-alpha"), @zen.ChatCompletions)
}

///|
test "parse_go_usage decodes the three windows or fails loudly" {
  let now = 1_000L
  // Live envelope shape.
  let envelope = Json::object(
    Map::from_array([
      (
        "usage",
        Json::object(
          Map::from_array([
            (
              "rolling",
              Json::object(
                Map::from_array([
                  ("percent", Json::number(11.0)),
                  ("resetsAt", Json::string("2026-10-14T20:00:00Z")),
                  ("status", Json::string("ok")),
                ]),
              ),
            ),
            (
              "weekly",
              Json::object(
                Map::from_array([
                  ("percent", Json::number(28.0)),
                  ("resetsAt", Json::string("2026-10-20T00:00:00Z")),
                  ("status", Json::string("ok")),
                ]),
              ),
            ),
            (
              "monthly",
              Json::object(
                Map::from_array([
                  ("percent", Json::number(14.0)),
                  ("resetsAt", Json::string("2026-11-07T08:55:00Z")),
                  ("status", Json::string("rate-limited")),
                ]),
              ),
            ),
          ]),
        ),
      ),
    ]),
  )
  let usage = parse_go_usage(envelope, fetched_at_ms=now)
  guard usage is Ok(parsed) else { fail("expected a valid usage payload") }
  assert_eq(parsed.rolling.percent, 11.0)
  assert_false(parsed.rolling.rate_limited)
  assert_eq(parsed.weekly.percent, 28.0)
  assert_eq(parsed.monthly.percent, 14.0)
  assert_true(parsed.monthly.rate_limited)
  // An absolute reset time parses into epoch millis (here: 2026-11-07Z).
  guard parsed.monthly.reset_at_ms is Some(reset) else {
    fail("expected a reset time for the monthly window")
  }
  assert_true(reset > now)
  // The unwrapped root shape parses identically.
  let unwrapped = Json::object(
    Map::from_array([
      (
        "rolling",
        Json::object(Map::from_array([("percent", Json::number(0.0))])),
      ),
      (
        "weekly",
        Json::object(Map::from_array([("percent", Json::number(0.0))])),
      ),
      (
        "monthly",
        Json::object(Map::from_array([("percent", Json::number(0.0))])),
      ),
    ]),
  )
  guard parse_go_usage(unwrapped, fetched_at_ms=now) is Ok(_) else {
    fail("expected the unwrapped shape to parse")
  }
  // A missing window is a typed error — never three fabricated zero rows.
  let broken = Json::object(Map::from_array([]))
  assert_true(parse_go_usage(broken, fetched_at_ms=now) is Err(_))
  let non_object = Json::array([])
  assert_true(parse_go_usage(non_object, fetched_at_ms=now) is Err(_))
}

///|
async test "go_binding_reset prefers the widest exhausted window" {
  let usage : GoUsage = {
    rolling: go_test_window(20.0, reset=Some(1L), limited=true),
    weekly: go_test_window(50.0, reset=Some(2L), limited=true),
    monthly: go_test_window(100.0, reset=Some(3L), limited=true),
    fetched_at_ms: 0L,
  }
  // Widest first: a monthly cap explains the refusal.
  assert_eq(go_binding_reset(usage), Some(3L))
  let usage_no_monthly : GoUsage = {
    rolling: go_test_window(20.0, reset=Some(1L), limited=true),
    weekly: go_test_window(50.0, reset=Some(2L), limited=true),
    monthly: go_test_window(14.0, limited=false),
    fetched_at_ms: 0L,
  }
  assert_eq(go_binding_reset(usage_no_monthly), Some(2L))
  let healthy : GoUsage = {
    rolling: go_test_window(11.0, limited=false),
    weekly: go_test_window(28.0, limited=false),
    monthly: go_test_window(14.0, limited=false),
    fetched_at_ms: 0L,
  }
  assert_eq(go_binding_reset(healthy), None)
}

//|

///|
fn go_test_window(
  percent : Double,
  reset~ : Int64? = None,
  limited~ : Bool = false,
) -> GoUsageWindow {
  { percent, reset_at_ms: reset, rate_limited: limited, }
}

///|
test "go plan allowances anchor the vendor table" {
  assert_eq(go_monthly_allowance("glm-5.3-flash", Go), Some(60.0))
  assert_eq(go_monthly_allowance("glm-5.3-flash", GoPlus), Some(180.0))
  assert_eq(go_monthly_allowance("glm-5.3", Go), Some(15.0))
  assert_eq(go_monthly_allowance("glm-5.3", GoPlus), Some(120.0))
  assert_eq(go_monthly_allowance("deepseek-v4.1-flash", Go), Some(80.0))
  assert_eq(go_monthly_allowance("deepseek-v4.1-flash", GoPlus), Some(160.0))
  assert_eq(go_monthly_allowance("claude-haiku-5-5", Go), Some(15.0))
  assert_eq(go_monthly_allowance("gemini-4-argon-contributor", Go), Some(60.0))
  // Limited-time free rows are Unlimited: no dollar figure exists.
  assert_eq(go_monthly_allowance("longcat-2.5-preview-free", Go), None)
  // Unknown ids stay unknown.
  assert_eq(go_monthly_allowance("omen-alpha", Go), None)
  // The plan setting parses strictly.
  assert_eq(go_plan_of_setting("go"), Go)
  assert_eq(go_plan_of_setting("go_plus"), GoPlus)
  let bad = Ok(go_plan_of_setting("ultra")) catch { error => Err(error) }
  assert_true(bad is Err(_))
}

///|
test "go catalog slots carry the Go identity and the right wire port" {
  let provider = OpenCodeGoProvider()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let models = @zen.parse_zen_models(
    Json::object(
      Map::from_array([
        ("object", Json::string("list")),
        (
          "data",
          Json::array([
            Json::object(
              Map::from_array([
                ("id", Json::string("glm-5.3-flash")),
                ("object", Json::string("model")),
                ("owned_by", Json::string("opencode")),
              ]),
            ),
            Json::object(
              Map::from_array([
                ("id", Json::string("claude-haiku-5-5")),
                ("object", Json::string("model")),
                ("owned_by", Json::string("opencode")),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  )
  let catalog = go_model_catalog(
    go_base_config(),
    models,
    "glm-5.3-flash",
    Map::from_array([]),
    api_key_factory,
  )
  assert_eq(catalog.provider_id, "opencode-go")
  let slots = catalog.slots()
  inspect(slots.length(), content="2")
  assert_eq(slots[0].model_id, "glm-5.3-flash")
  assert_eq(slots[0].display_group, Some("go"))
  assert_eq(slots[0].provider_id, "opencode-go")
  // Every slot's label carries the Go display prefix.
  debug_inspect(
    slots.map(slot => slot.label),
    content=(
      #|["Go / glm-5.3-flash", "Go / claude-haiku-5-5"]
    ),
  )
}

///|
test "go factory settings resolve with typed failures" {
  // ProviderConfigSource carries the provider-scoped settings object.
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-go-1")),
          ("model", Json::string("kimi-k3")),
          ("plan", Json::string("go_plus")),
        ]),
      ),
    ),
  )
  let auth = match go_resolve_auth(source) {
    Some(auth) => auth
    None => abort("expected an API-key auth")
  }
  assert_eq(auth.api_key, "sk-go-1")
  assert_false(auth.oauth)
  assert_eq(go_resolve_base_url(source, auth), go_default_base_url)
  assert_eq(go_resolve_model(source), "kimi-k3")
  assert_eq(go_resolve_plan(source), GoPlus)
  // An unknown plan is a typed composition failure.
  let bad_plan = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(Map::from_array([("plan", Json::string("mega"))])),
    ),
  )
  let result = Ok(go_resolve_plan(bad_plan)) catch { error => Err(error) }
  assert_true(result is Err(_))
  // Without settings the provider is unconfigured.
  let empty = @llm.ProviderConfigSource::ProviderConfigSource()
  assert_true(go_resolve_auth(empty) is None)
}

//|
//| DeepSeek serving contract (mounted on the `deepseek*` chat-completions
//| slots only).
//|

///|
fn go_settings_source(
  extra : Array[(String, Json)],
) -> @llm.ProviderConfigSource {
  let fields : Map[String, Json] = Map::from_array([
    ("api_key", Json::string("sk-go-1")),
  ])
  for entry in extra {
    fields[entry.0] = entry.1
  }
  @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(Json::object(fields)),
  )
}

///|
test "go_deepseek_applies is deepseek ids on the chat-completions wire" {
  let chat = @zen.OpenCodeZenConfig(
    "sk-go-test",
    base_url="https://opencode.ai/inference/go/v1",
    model="deepseek-v4.1-flash",
  )
  assert_true(go_deepseek_applies(chat))
  // The Messages wire rejects a system message inside the transcript, so the
  // convergence injection and the inspector stay off it.
  let on_messages : @zen.OpenCodeZenConfig = { ..chat, wire: @zen.Messages, }
  assert_false(go_deepseek_applies(on_messages))
  let other_model : @zen.OpenCodeZenConfig = { ..chat, model: "glm-5.3-flash", }
  assert_false(go_deepseek_applies(other_model))
}

///|
test "go_deepseek_policy resolves defaults, opt-outs, and typed failures" {
  // `build` parses the contract even though the default model is a glm slot.
  let bare = go_settings_source([])
  let built = Ok(OpenCodeGoProvider().build(bare)) catch { error => Err(error) }
  assert_true(built is Ok(_))
  let defaults = go_deepseek_policy(bare)
  assert_eq(defaults, @ds.DeepSeekPolicy::default_protections())
  assert_eq(defaults.max_reasoning_chars, Some(120000))
  assert_eq(defaults.repeated_reasoning_span_chars, Some(256))
  assert_true(defaults.recover_on_reasoning_exhaustion)
  let opt_out = go_settings_source([
    ("max_reasoning_chars", Json::null()),
    ("repeated_reasoning_span_chars", Json::null()),
    ("recover_on_reasoning_exhaustion", Json::boolean(false)),
  ])
  assert_eq(go_deepseek_policy(opt_out), @ds.DeepSeekPolicy::disabled())
  // A malformed value is a typed composition failure, never a silent fallback.
  let malformed = go_settings_source([
    ("max_reasoning_chars", Json::string("lots")),
  ])
  let result = Ok(OpenCodeGoProvider().build(malformed)) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("max_reasoning_chars"))
    _ => fail("expected a typed composition failure for a malformed key")
  }
}

///|
fn go_reasoning_accumulator(
  reasoning : String,
) -> @posoco.StreamAccumulator raise {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  acc.push(@posoco.StreamChunk::ReasoningDelta(token=reasoning))
  acc
}

///|
test "go_deepseek_inspector relays the kit's stream bounds" {
  let budget = @ds.DeepSeekPolicy::DeepSeekPolicy(
    max_reasoning_chars=Some(64),
    repeated_reasoning_span_chars=None,
    recover_on_reasoning_exhaustion=false,
  )
  let ctx = @devkit.ExtContext::default()
  let inspect_budget = go_deepseek_inspector(budget, ctx)
  assert_true(
    inspect_budget(go_reasoning_accumulator("thinking"), false)
    is @zen.StreamVerdict::Continue,
  )
  match inspect_budget(go_reasoning_accumulator("x".repeat(65)), false) {
    @zen.StreamVerdict::Continue => fail("expected a budget abort")
    @zen.StreamVerdict::Abort(category~, message~) => {
      assert_eq(category, "reasoning_budget_exceeded")
      assert_eq(
        message, "DeepSeek reasoning stream exceeded configured max_reasoning_chars",
      )
    }
  }
  let repetition = @ds.DeepSeekPolicy::DeepSeekPolicy(
    max_reasoning_chars=Some(120000),
    repeated_reasoning_span_chars=Some(128),
    recover_on_reasoning_exhaustion=false,
  )
  let inspect_repetition = go_deepseek_inspector(repetition, ctx)
  let span = "y".repeat(128)
  match
    inspect_repetition(go_reasoning_accumulator(span + span + span), false) {
    @zen.StreamVerdict::Continue => fail("expected a repetition abort")
    @zen.StreamVerdict::Abort(category~, message~) => {
      assert_eq(category, "reasoning_repetition")
      assert_eq(message, "DeepSeek stream reasoning repetition detected")
    }
  }
  // A completed stream is never re-judged: a finished answer that happens to
  // end repetitively is legitimate.
  assert_true(
    inspect_repetition(go_reasoning_accumulator(span + span + span), true)
    is @zen.StreamVerdict::Continue,
  )
}

///|
test "deepseek slots keep the catalog shape next to other models" {
  let provider = OpenCodeGoProvider()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let models = @zen.parse_zen_models(
    Json::object(
      Map::from_array([
        ("object", Json::string("list")),
        (
          "data",
          Json::array([
            Json::object(
              Map::from_array([
                ("id", Json::string("deepseek-v4.1-flash")),
                ("object", Json::string("model")),
                ("owned_by", Json::string("opencode")),
              ]),
            ),
            Json::object(
              Map::from_array([
                ("id", Json::string("glm-5.3-flash")),
                ("object", Json::string("model")),
                ("owned_by", Json::string("opencode")),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  )
  let policy = @ds.DeepSeekPolicy::default_protections()
  let guarded = go_model_catalog(
    go_base_config(),
    models,
    "deepseek-v4.1-flash",
    Map::from_array([]),
    api_key_factory,
    policy=Some(policy),
  )
  let plain = go_model_catalog(
    go_base_config(),
    models,
    "deepseek-v4.1-flash",
    Map::from_array([]),
    api_key_factory,
  )
  inspect(guarded.slots().length(), content="2")
  // The contract is a port decorator: the slot surface is byte-identical.
  assert_eq(
    guarded.slots().map(slot => slot.id),
    plain.slots().map(slot => slot.id),
  )
  assert_eq(
    guarded.slots().map(slot => slot.label),
    plain.slots().map(slot => slot.label),
  )
  assert_eq(
    guarded.slots().map(slot => slot.capabilities),
    plain.slots().map(slot => slot.capabilities),
  )
  assert_eq(guarded.slots()[0].id, "opencode-go/deepseek-v4.1-flash")
  assert_eq(guarded.slots()[0].label, "Go / deepseek-v4.1-flash")
  assert_eq(guarded.slots()[0].display_group, Some("go"))
  assert_eq(guarded.slots()[1].id, "opencode-go/glm-5.3-flash")
  assert_eq(guarded.slots()[1].label, "Go / glm-5.3-flash")
}

///|
fn go_test_json(text : String) -> Json {
  @json.parse(text) catch {
    _ => abort("invalid JSON fixture: " + text)
  }
}

///|
fn go_test_device(
  server~ : String = "https://opencode.ai/console",
) -> GoDeviceAuth {
  let payload = go_test_json(
    "{\"device_code\":\"dev-1\",\"user_code\":\"ABCD-1234\",\"verification_uri_complete\":\"/console/device?code=ABCD-1234\",\"expires_in\":600,\"interval\":5}",
  )
  match parse_go_device_auth(server, payload) {
    Ok(device) => device
    Err(message) => abort(message)
  }
}

///|
test "Console device answer keeps the origin of a relative verification URL" {
  let device = go_test_device()
  assert_eq(device.device_code, "dev-1")
  assert_eq(device.user_code, "ABCD-1234")
  assert_eq(
    device.verification_url,
    "https://opencode.ai/console/device?code=ABCD-1234",
  )
  assert_eq(device.expires_in, 600)
  assert_eq(device.interval, 5)
  assert_eq(
    go_resolve_verification_url(
      "https://opencode.ai/console", "https://opencode.ai/console/device?code=X",
    ),
    Some("https://opencode.ai/console/device?code=X"),
  )
  assert_eq(
    go_resolve_verification_url(
      "https://opencode.ai/console", "javascript:alert(1)",
    ),
    None,
  )
}

///|
test "device-token polls separate pending, throttling, grants, and refusals" {
  assert_true(
    parse_go_token_poll(
      400,
      go_test_json("{\"error\":\"authorization_pending\"}"),
    )
    is Pending,
  )
  assert_true(
    parse_go_token_poll(400, go_test_json("{\"error\":\"slow_down\"}"))
    is SlowDown,
  )
  // Transient gateway fault.
  assert_true(
    parse_go_token_poll(503, go_test_json("{\"error\":\"server_error\"}"))
    is Pending,
  )
  assert_true(
    parse_go_token_poll(400, go_test_json("{\"error\":\"access_denied\"}"))
    is Failed("access_denied"),
  )
  match
    parse_go_token_poll(
      200,
      go_test_json(
        "{\"access_token\":\"at-1\",\"refresh_token\":\"rt-1\",\"expires_in\":2592000,\"org_id\":\"org_1\"}",
      ),
    ) {
    Granted(token) => {
      assert_eq(token.access_token, "at-1")
      assert_eq(token.refresh_token, "rt-1")
      assert_eq(token.expires_in, 2592000)
      assert_eq(token.org_id, Some("org_1"))
    }
    _ => fail("expected a granted token")
  }
}

///|
test "organization choice prefers the Go-carrying workspace" {
  let orgs = [
    GoOrg::{ id: "org_b", name: "Beta", },
    GoOrg::{ id: "org_a", name: "Alpha", },
  ]
  let apis : Map[String, String] = Map::from_array([
    ("org_b", "https://opencode.ai/inference/go/v1"),
  ])
  match choose_go_org(orgs, None, apis, true) {
    Ok(choice) => {
      assert_eq(choice.org.id, "org_b")
      assert_eq(choice.api_base, Some("https://opencode.ai/inference/go/v1"))
    }
    Err(message) => abort(message)
  }
  // A scoped grant wins over the Go-carrying workspace.
  match choose_go_org(orgs, Some("org_a"), apis, true) {
    Ok(choice) => assert_eq(choice.org.id, "org_a")
    Err(message) => abort(message)
  }
  // All probes answered, none carries Go.
  match choose_go_org(orgs, None, Map::from_array([]), true) {
    Ok(_) => fail("expected a no-Go failure")
    Err(message) =>
      assert_true(message.contains("no organisation with OpenCode Go"))
  }
  // A failed probe does not block the login.
  match choose_go_org(orgs, None, Map::from_array([]), false) {
    Ok(choice) => assert_eq(choice.org.id, "org_a")
    Err(message) => abort(message)
  }
}

///|
test "Console config payloads yield the versioned inference base" {
  let v2 = go_test_json(
    "{\"providers\":{\"opencode-go\":{\"settings\":{\"baseURL\":\"https://opencode.ai/inference/go/openai/v1\"}}}}",
  )
  assert_eq(
    parse_go_config_api(v2),
    Some("https://opencode.ai/inference/go/v1"),
  )
  let legacy = go_test_json(
    "{\"config\":{\"provider\":{\"opencode-go\":{\"api\":\"https://example.test/go/openai/v1/\"}}}}",
  )
  assert_eq(parse_go_config_api(legacy), Some("https://example.test/go/v1"))
  assert_eq(parse_go_config_api(go_test_json("{}")), None)
  assert_eq(
    go_normalize_api_base("https://opencode.ai/inference/go/v1"),
    Some("https://opencode.ai/inference/go/v1"),
  )
  assert_eq(go_normalize_api_base("file:///etc/passwd"), None)
}

///|
test "account grants project into the Go plane without losing routing" {
  let token = GoOAuthToken::{
    access_token: "at-1",
    refresh_token: "rt-1",
    expires_in: 3600,
    org_id: Some("org_1"),
  }
  let credential = go_oauth_credential_from_login(
    token,
    "https://opencode.ai/console",
    org=GoOrg::{ id: "org_1", name: "Team", },
    api_base=Some("https://opencode.ai/inference/go/v1"),
    email=Some("dev@example.test"),
    now_secs=1000,
  )
  assert_eq(credential.access_token, "at-1")
  assert_eq(credential.expires_at, 4600)
  assert_eq(credential.metadata_value("org_id"), Some("org_1"))
  assert_eq(
    credential.metadata_value("api_base"),
    Some("https://opencode.ai/inference/go/v1"),
  )
  let session = match go_oauth_session(credential) {
    Some(session) => session
    None => abort("expected a usable grant")
  }
  assert_eq(session.org_id, Some("org_1"))
  assert_eq(session.server, "https://opencode.ai/console")
  // Margin is 300s.
  assert_false(go_oauth_is_expiring(session, 4299))
  assert_true(go_oauth_is_expiring(session, 4300))
  let rotated = go_oauth_refreshed_credential(
    credential,
    GoOAuthToken::{
      access_token: "at-2",
      refresh_token: "rt-2",
      expires_in: 3600,
      org_id: None,
    },
    now_secs=5000,
  )
  assert_eq(rotated.access_token, "at-2")
  assert_eq(rotated.refresh_token, "rt-2")
  assert_eq(rotated.expires_at, 8600)
  assert_eq(rotated.metadata_value("org_id"), Some("org_1"))
  assert_eq(rotated.metadata_value("email"), Some("dev@example.test"))
  assert_eq(go_extra_headers(Some("org_1"))["x-opencode-org-id"], "org_1")
  assert_true(go_extra_headers(None).is_empty())
}

///|
test "an OAuth credential composes a Go catalog with its organization" {
  let credential = go_oauth_credential_from_login(
    GoOAuthToken::{
      access_token: "at-1",
      refresh_token: "rt-1",
      expires_in: 3600,
      org_id: Some("org_1"),
    },
    "https://opencode.ai/console",
    org=GoOrg::{ id: "org_1", name: "Team", },
    api_base=Some("https://opencode.ai/inference/go/v1"),
    now_secs=1000,
  )
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    provider_credential=Some(@oauth.ProviderCredential::OAuth(credential)),
  )
  let auth = match go_resolve_auth(source) {
    Some(auth) => auth
    None => abort("expected a configured auth")
  }
  assert_true(auth.oauth)
  assert_eq(auth.org_id, Some("org_1"))
  assert_eq(auth.api_base, Some("https://opencode.ai/inference/go/v1"))
  assert_eq(
    go_resolve_base_url(source, auth),
    "https://opencode.ai/inference/go/v1",
  )
  let provider = OpenCodeGoProvider()
  match @llm.ProviderFactory::build(provider, source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      assert_eq(catalog.slots().length(), 1)
      match catalog.slots()[0].rebuild_on_credential {
        Some(rebuild) => {
          let rebuilt_slot = rebuild(credential)
          assert_eq(rebuilt_slot.id, catalog.slots()[0].id)
        }
        None => fail("expected an OAuth credential rebuild hook")
      }
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected a configured Go catalog")
  }
}

///|
test "go_model_catalog drops SystemOne ids from the live catalog" {
  let provider = OpenCodeGoProvider()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let payload = Json::object(
    Map::from_array([
      ("object", Json::string("list")),
      (
        "data",
        Json::array([
          Json::object(
            Map::from_array([
              ("id", Json::string("jev-1.13")),
              ("object", Json::string("model")),
              ("owned_by", Json::string("opencode")),
            ]),
          ),
          Json::object(
            Map::from_array([
              ("id", Json::string("glm-5.3-flash")),
              ("object", Json::string("model")),
              ("owned_by", Json::string("opencode")),
            ]),
          ),
        ]),
      ),
    ]),
  )
  let catalog = go_model_catalog(
    go_base_config(),
    @zen.parse_zen_models(payload),
    "glm-5.3-flash",
    Map::from_array([]),
    api_key_factory,
  )
  let slots = catalog.slots()
  assert_eq(slots.length(), 1)
  assert_eq(slots[0].model_id, "glm-5.3-flash")
  assert_true(slots[0].is_chat())
  assert_false(catalog.capabilities().contains("decision"))
}
