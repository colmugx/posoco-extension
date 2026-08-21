///|
/// White-box tests for posoco-ext-opencode-zen.
///
/// These exercise the pure parse/catalog/build/login logic without network.
/// The live `/models` fetch is covered indirectly through `parse_zen_models`
/// (its decoder) plus the cetas-core integration paths; no HTTP is issued here.

///|
/// Provider-neutral prompt fake used to exercise the API-key seam.
struct ZenApiKeyPrompt {
  value : String
}

///|
pub impl @oauth.AuthPromptInteraction for ZenApiKeyPrompt with fn prompt(
  self : ZenApiKeyPrompt,
  _request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  self.value
}

///|
/// Build a settings JSON object from key/value pairs.
fn zen_settings(pairs : Array[(String, String)]) -> Json {
  Json::object(
    Map::from_array(pairs.map(pair => (pair.0, Json::string(pair.1)))),
  )
}

///|
test "Zen routing headers carry stable session and fresh request identity" {
  let session = zen_new_session_id()
  let first = zen_request_headers(session)
  let second = zen_request_headers(session)
  assert_eq(first["x-opencode-project"], Some("posoco"))
  assert_eq(first["x-opencode-session"], Some(session))
  assert_eq(first["x-opencode-client"], Some("posoco"))
  assert_eq(first["User-Agent"], Some("posoco/opencode-zen"))
  assert_true(first["x-opencode-request"] != second["x-opencode-request"])
}

///|
/// A representative slice of Zen's real /models response (shape verified by
/// probe against https://opencode.ai/zen/v1/models). Bare ids, all owned_by
/// "opencode".
fn zen_sample_models_payload() -> Json {
  Json::object(
    Map::from_array([
      ("object", Json::string("list")),
      (
        "data",
        Json::array([
          Json::object(
            Map::from_array([
              ("id", Json::string("claude-opus-5")),
              ("object", Json::string("model")),
              ("created", Json::number(1785984130.0)),
              ("owned_by", Json::string("opencode")),
            ]),
          ),
          Json::object(
            Map::from_array([
              ("id", Json::string("gpt-5.1-codex")),
              ("object", Json::string("model")),
              ("created", Json::number(1785984130.0)),
              ("owned_by", Json::string("opencode")),
            ]),
          ),
          Json::object(
            Map::from_array([
              ("id", Json::string("glm-5.2")),
              ("object", Json::string("model")),
              ("created", Json::number(1785984130.0)),
              ("owned_by", Json::string("opencode")),
            ]),
          ),
        ]),
      ),
    ]),
  )
}

///|
test "parse_zen_models decodes a standard OpenAI ListModels envelope" {
  let models = parse_zen_models(zen_sample_models_payload())
  inspect(models.length(), content="3")
  debug_inspect(
    models.map(info => info.id),
    content=(
      #|["claude-opus-5", "gpt-5.1-codex", "glm-5.2"]
    ),
  )
  assert_true(models.every(info => info.owned_by == "opencode"))
}

///|
test "parse_zen_models rejects a non-object root" {
  try parse_zen_models(Json::array([])) catch {
    @posoco.ModelError::ResponseParse(msg) =>
      assert_true(msg.contains("must be an object"))
    _ =>
      fail("expected ResponseParse for non-object root, got another ModelError")
  } noraise {
    _ => fail("expected ResponseParse for non-object root")
  }
}

///|
test "parse_zen_models rejects a missing object field" {
  let payload = Json::object(Map::from_array([("data", Json::array([]))]))
  try parse_zen_models(payload) catch {
    @posoco.ModelError::ResponseParse(msg) =>
      assert_true(msg.contains("missing object"))
    _ =>
      fail("expected ResponseParse for missing object, got another ModelError")
  } noraise {
    _ => fail("expected ResponseParse for missing object")
  }
}

///|
test "parse_zen_models rejects data that is not an array" {
  let payload = Json::object(
    Map::from_array([
      ("object", Json::string("list")),
      ("data", Json::string("oops")),
    ]),
  )
  try parse_zen_models(payload) catch {
    @posoco.ModelError::ResponseParse(msg) =>
      assert_true(msg.contains("data must be an array"))
    _ =>
      fail("expected ResponseParse for non-array data, got another ModelError")
  } noraise {
    _ => fail("expected ResponseParse for non-array data")
  }
}

///|
test "parse_zen_models rejects an item missing id" {
  let payload = Json::object(
    Map::from_array([
      ("object", Json::string("list")),
      (
        "data",
        Json::array([
          Json::object(
            Map::from_array([
              ("object", Json::string("model")),
              ("owned_by", Json::string("opencode")),
            ]),
          ),
        ]),
      ),
    ]),
  )
  try parse_zen_models(payload) catch {
    @posoco.ModelError::ResponseParse(msg) =>
      assert_true(msg.contains("missing string id"))
    _ =>
      fail("expected ResponseParse for item missing id, got another ModelError")
  } noraise {
    _ => fail("expected ResponseParse for item missing id")
  }
}

///|
test "parse_zen_models rejects an item with wrong object value" {
  let payload = Json::object(
    Map::from_array([
      ("object", Json::string("list")),
      (
        "data",
        Json::array([
          Json::object(
            Map::from_array([
              ("id", Json::string("foo")),
              ("object", Json::string("not-a-model")),
              ("owned_by", Json::string("opencode")),
            ]),
          ),
        ]),
      ),
    ]),
  )
  try parse_zen_models(payload) catch {
    @posoco.ModelError::ResponseParse(msg) =>
      assert_true(msg.contains("object must be model"))
    _ =>
      fail(
        "expected ResponseParse for wrong object value, got another ModelError",
      )
  } noraise {
    _ => fail("expected ResponseParse for wrong object value")
  }
}

///|
/// Build a base config used by the multi-slot catalog tests.
fn zen_base_config() -> @openai_compatible.OpenAICompatibleConfig {
  @openai_compatible.OpenAICompatibleConfig::new(
    "sk-test",
    base_url="https://opencode.ai/zen/v1",
    model="gpt-5.1-codex",
  )
}

///|
test "zen_model_catalog builds one slot per discovered model" {
  let provider = OpenCodeZenProvider::new()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let models = parse_zen_models(zen_sample_models_payload())
  let catalog = zen_model_catalog(
    zen_base_config(),
    models,
    "gpt-5.1-codex",
    api_key_factory,
  )
  assert_eq(catalog.provider_id, "opencode")
  let slots = catalog.slots()
  inspect(slots.length(), content="3")
  assert_eq(slots[0].model_id, "gpt-5.1-codex")
  debug_inspect(
    slots.map(slot => slot.id),
    content=(
      #|[
      #|  "opencode/gpt-5.1-codex",
      #|  "opencode/claude-opus-5",
      #|  "opencode/glm-5.2",
      #|]
    ),
  )
  assert_true(slots.every(slot => slot.display_group == Some("zen")))
  assert_true(slots.every(slot => slot.capabilities.contains("chat")))
}

///|
test "zen_model_catalog raises on an empty model list" {
  let provider = OpenCodeZenProvider::new()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let result = Ok(
    zen_model_catalog(zen_base_config(), [], "any", api_key_factory),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("empty catalog"))
    _ => fail("expected ManifestSchemaError for empty catalog")
  }
}

///|
test "zen_model_catalog falls back to server order when preferred is absent" {
  let provider = OpenCodeZenProvider::new()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let models = parse_zen_models(zen_sample_models_payload())
  let catalog = zen_model_catalog(
    zen_base_config(),
    models,
    "nonexistent",
    api_key_factory,
  )
  let slots = catalog.slots()
  debug_inspect(
    slots.map(slot => slot.model_id),
    content=(
      #|["claude-opus-5", "gpt-5.1-codex", "glm-5.2"]
    ),
  )
}

///|
test "zen_static_catalog builds a single slot over the resolved model" {
  let provider = OpenCodeZenProvider::new()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let catalog = zen_static_catalog(zen_base_config(), api_key_factory)
  let slots = catalog.slots()
  assert_true(slots.length() == 1)
  assert_eq(slots[0].model_id, "gpt-5.1-codex")
  assert_eq(slots[0].id, "opencode/gpt-5.1-codex")
}

///|
test "OpenCodeZenProvider reports the opencode provider and credential id" {
  let provider = OpenCodeZenProvider::new()
  let factory : &@llm.ProviderFactory = provider
  assert_eq(factory.provider_id(), "opencode")
  assert_eq(factory.credential_id(), "opencode")
}

///|
test "ProviderFactory::build returns Unconfigured without any api key" {
  let provider = OpenCodeZenProvider::new()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(zen_settings([("model", "claude-opus-5")])),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Unconfigured => ()
    @llm.ProviderBuildResult::Ready(_) =>
      fail("expected Unconfigured when api_key is missing")
  }
}

///|
test "ProviderFactory::build with api_key produces a single-slot Ready catalog" {
  let provider = OpenCodeZenProvider::new()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      zen_settings([("api_key", "sk-zen-test"), ("model", "claude-sonnet-5")]),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      assert_eq(catalog.provider_id, "opencode")
      let slots = catalog.slots()
      assert_true(slots.length() == 1)
      assert_eq(slots[0].provider_id, "opencode")
      assert_eq(slots[0].model_id, "claude-sonnet-5")
      assert_eq(slots[0].id, "opencode/claude-sonnet-5")
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with api_key present")
  }
}

///|
test "ProviderFactory::build applies the default model when omitted" {
  let provider = OpenCodeZenProvider::new()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(zen_settings([("api_key", "sk-zen-test")])),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      assert_eq(slot.model_id, "claude-sonnet-5")
      assert_eq(slot.id, "opencode/claude-sonnet-5")
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with defaults applied")
  }
}

///|
test "ProviderFactory::build prefers api_key credential over the setting" {
  let provider = OpenCodeZenProvider::new()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      zen_settings([("api_key", "sk-from-settings"), ("model", "glm-5.2")]),
    ),
    provider_credential=Some(
      @oauth.ProviderCredential::ApiKey(
        @oauth.ApiKeyCredential::ApiKeyCredential(secret="sk-from-login"),
      ),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(_) => ()
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready when api_key credential is present")
  }
}

///|
/// The host-cached record shape: a previous refresh projected to slot
/// records. Zen only consumes `model_id`; extra fields ride along untouched.
fn cached_records(ids : Array[String]) -> Json {
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
  let provider = OpenCodeZenProvider::new()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      zen_settings([("api_key", "sk-zen-test"), ("model", "gpt-5.1-codex")]),
    ),
    cached_models=Some(
      cached_records(["gpt-5.1-codex", "claude-opus-5", "glm-5.2"]),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slots = catalog.slots()
      assert_eq(slots.length(), 3)
      // The configured (preferred) model is pinned first, cache order after.
      assert_eq(slots[0].id, "opencode/gpt-5.1-codex")
      assert_eq(slots[1].id, "opencode/claude-opus-5")
      assert_eq(slots[2].id, "opencode/glm-5.2")
      assert_eq(slots[0].display_group, Some("zen"))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog from cached records")
  }
}

///|
test "ProviderFactory::build degrades to the static slot on bad cached records" {
  let provider = OpenCodeZenProvider::new()
  let factory : &@llm.ProviderFactory = provider
  for
    bad in [
      Json::array([]),
      Json::string("not-an-array"),
      Json::object(Map::from_array([])),
      Json::array([Json::string("bare-id")]),
      Json::array([
        Json::object(Map::from_array([("model_id", Json::string("ok"))])),
        Json::object(Map::from_array([("model_id", Json::string(""))])),
      ]),
    ] {
    let source = @llm.ProviderConfigSource::ProviderConfigSource(
      settings=Some(zen_settings([("api_key", "sk-zen-test")])),
      cached_models=Some(bad),
    )
    match factory.build(source) {
      @llm.ProviderBuildResult::Ready(catalog) => {
        let slots = catalog.slots()
        assert_true(slots.length() == 1)
        assert_eq(slots[0].model_id, "claude-sonnet-5")
      }
      @llm.ProviderBuildResult::Unconfigured =>
        fail(
          "bad cache records must degrade to the static build, not Unconfigured",
        )
    }
  }
}

///|
test "ProviderFactory::build rejects an OAuth credential with a typed error" {
  let provider = OpenCodeZenProvider::new()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(zen_settings([("model", "glm-5.2")])),
    provider_credential=Some(
      @oauth.ProviderCredential::OAuth(
        @oauth.Credential::Credential(
          access_token="ignored",
          refresh_token="",
          expires_at=0,
          metadata=Map::from_array([]),
        ),
      ),
    ),
  )
  let result = Ok(factory.build(source)) catch { error => Err(error) }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("OAuth credential is not supported"))
    _ => fail("expected ManifestSchemaError for OAuth credential")
  }
}

///|
async test "ApiKeyFactory::login validates and returns the secret" {
  let provider = OpenCodeZenProvider::new()
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = ZenApiKeyPrompt::{ value: "sk-via-login" }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let credential = api.login(prompt)
  assert_eq(credential.secret, "sk-via-login")
}

///|
async test "ApiKeyFactory::login rejects an empty secret" {
  let provider = OpenCodeZenProvider::new()
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = ZenApiKeyPrompt::{ value: "" }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let result = Ok(api.login(prompt)) catch { error => Err(error) }
  match result {
    Err(@oauth.OAuthError::ParseError(message)) =>
      assert_true(message.contains("must not be empty"))
    _ => fail("expected empty API key to fail")
  }
}

///|
test "zen_model_catalog presets per-model effort surfaces from the table" {
  let provider = OpenCodeZenProvider::new()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let models = parse_zen_models(zen_sample_models_payload())
  let catalog = zen_model_catalog(
    zen_base_config(),
    models,
    "gpt-5.1-codex",
    api_key_factory,
  )
  let slots = catalog.slots()
  // gpt-5.1-codex: declared levels, cannot disable → no "off" entry.
  debug_inspect(
    slots[0].thinking_efforts,
    content=(
      #|["low", "medium", "high"]
    ),
  )
  assert_eq(slots[0].default_effort, Some("high"))
  // claude-opus-5: levels include xhigh/max, no "off" either.
  debug_inspect(
    slots[1].thinking_efforts,
    content=(
      #|["low", "medium", "high", "xhigh", "max"]
    ),
  )
  // glm-5.2: high/max only.
  debug_inspect(
    slots[2].thinking_efforts,
    content=(
      #|["high", "max"]
    ),
  )
}

///|
test "zen slot rebuild_on_effort reselects the level" {
  let provider = OpenCodeZenProvider::new()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let catalog = zen_static_catalog(zen_base_config(), api_key_factory)
  let slot = catalog.slots()[0]
  assert_eq(slot.id, "opencode/gpt-5.1-codex")
  guard slot.rebuild_on_effort is Some(rebuild) else {
    fail("expected a rebuild_on_effort hook for a level-bearing model")
  }
  let lowered = rebuild("medium")
  assert_eq(lowered.default_effort, Some("medium"))
  debug_inspect(
    lowered.thinking_efforts,
    content=(
      #|["low", "medium", "high"]
    ),
  )
}

///|
test "zen effort presets cover toggle-only and unknown models" {
  // Toggle-only: kimi-k2.6 exposes the off/on toggle with no levels and
  // starts off (the wire omits the reasoning surface).
  guard zen_effort_preset("kimi-k2.6") is Some(preset) else {
    fail("expected a preset for kimi-k2.6")
  }
  assert_true(preset.levels.is_empty())
  assert_true(preset.can_disable)
  // Unknown models stay plain chat: no selector at all.
  assert_true(zen_effort_preset("some-future-model") is None)

  let provider = OpenCodeZenProvider::new()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let toggle_slot = zen_catalog_slot(
    zen_config_for_model(zen_base_config(), "kimi-k2.6"),
    api_key_factory,
  )
  debug_inspect(
    toggle_slot.thinking_efforts,
    content=(
      #|["off", "on"]
    ),
  )
  assert_eq(toggle_slot.default_effort, Some("off"))
  let plain_slot = zen_catalog_slot(
    zen_config_for_model(zen_base_config(), "some-future-model"),
    api_key_factory,
  )
  debug_inspect(
    plain_slot.thinking_efforts,
    content=(
      #|[]
    ),
  )
  assert_eq(plain_slot.default_effort, None)
  assert_true(plain_slot.rebuild_on_effort is None)
}
