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
  assert_eq(go_resolve_api_key(source), Some("sk-go-1"))
  assert_eq(go_resolve_base_url(source), go_default_base_url)
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
  assert_eq(go_resolve_api_key(empty), None)
}
