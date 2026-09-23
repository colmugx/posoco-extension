///|
/// White-box tests for posoco-ext-opencode-zen.
///
/// These exercise the pure parse/catalog/build/login logic without network.
/// The live `/models` fetch and the models.dev surfaces fetch are covered
/// indirectly through their decoders (`parse_zen_models`,
/// `parse_models_dev_surfaces`) plus the cetas-core integration paths; no
/// HTTP is issued here.

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
pub extend ZenApiKeyPrompt with @colmugx/posoco-ext-oauth.AuthPromptInteraction::{
  prompt,
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
  let first = zen_request_headers()
  let second = zen_request_headers()
  assert_eq(first["x-opencode-project"], "posoco")
  assert_eq(first["x-opencode-client"], "posoco")
  assert_eq(first["User-Agent"], "posoco/opencode-zen")
  assert_eq(first["x-opencode-session"], second["x-opencode-session"])
  assert_true(first["x-opencode-session"].length() > 0)
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
/// One reasoning_options entry of a models.dev model object.
fn zen_reasoning_option(kind~ : String, values? : Array[Json]) -> Json {
  let fields = Map::from_array([("type", Json::string(kind))])
  match values {
    Some(values) => fields["values"] = Json::array(values)
    None => ()
  }
  Json::object(fields)
}

///|
/// A representative slice of the models.dev opencode provider entry (shapes
/// verified against https://models.opencode.ai/api.json).
fn models_dev_sample_payload() -> Json {
  Json::object(
    Map::from_array([
      (
        "opencode",
        Json::object(
          Map::from_array([
            (
              "models",
              Json::object(
                Map::from_array([
                  // Real sample: effort levels including "none", no toggle.
                  (
                    "gpt-5.1",
                    Json::object(
                      Map::from_array([
                        ("reasoning", Json::boolean(true)),
                        (
                          "reasoning_options",
                          Json::array([
                            zen_reasoning_option(kind="effort", values=[
                              Json::string("none"),
                              Json::string("low"),
                              Json::string("medium"),
                              Json::string("high"),
                            ]),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                  // Real sample: bare toggle.
                  (
                    "kimi-k2.5",
                    Json::object(
                      Map::from_array([
                        ("reasoning", Json::boolean(true)),
                        (
                          "reasoning_options",
                          Json::array([zen_reasoning_option(kind="toggle")]),
                        ),
                      ]),
                    ),
                  ),
                  // Real sample: toggle and effort levels side by side.
                  (
                    "deepseek-v4-flash",
                    Json::object(
                      Map::from_array([
                        ("reasoning", Json::boolean(true)),
                        (
                          "reasoning_options",
                          Json::array([
                            zen_reasoning_option(kind="toggle"),
                            zen_reasoning_option(kind="effort", values=[
                              Json::string("low"),
                              Json::string("high"),
                              Json::string("max"),
                            ]),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                  // Real sample: plain chat model.
                  (
                    "claude-3-5-haiku",
                    Json::object(
                      Map::from_array([("reasoning", Json::boolean(false))]),
                    ),
                  ),
                  // Real sample: budget tokens, no declared levels.
                  (
                    "claude-haiku-4-5",
                    Json::object(
                      Map::from_array([
                        ("reasoning", Json::boolean(true)),
                        (
                          "reasoning_options",
                          Json::array([
                            zen_reasoning_option(kind="budget_tokens"),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                  // Real sample: reasons but declares no options.
                  (
                    "union-alpha",
                    Json::object(
                      Map::from_array([
                        ("reasoning", Json::boolean(true)),
                        ("reasoning_options", Json::array([])),
                      ]),
                    ),
                  ),
                  // Missing reasoning_options entirely.
                  (
                    "no-options-model",
                    Json::object(
                      Map::from_array([("reasoning", Json::boolean(true))]),
                    ),
                  ),
                  // The generic schema may emit null levels; opencode reads
                  // them back as "none".
                  (
                    "null-level-model",
                    Json::object(
                      Map::from_array([
                        ("reasoning", Json::boolean(true)),
                        (
                          "reasoning_options",
                          Json::array([
                            zen_reasoning_option(kind="effort", values=[
                              Json::null(),
                              Json::string("high"),
                            ]),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                  // Unknown option shapes are ignored.
                  (
                    "mystery-option-model",
                    Json::object(
                      Map::from_array([
                        ("reasoning", Json::boolean(true)),
                        (
                          "reasoning_options",
                          Json::array([zen_reasoning_option(kind="quantum")]),
                        ),
                      ]),
                    ),
                  ),
                  // Malformed entry: reasoning_options is not an array.
                  (
                    "junk-options-model",
                    Json::object(
                      Map::from_array([
                        ("reasoning", Json::boolean(true)),
                        ("reasoning_options", Json::string("oops")),
                      ]),
                    ),
                  ),
                  // Malformed entry: not an object at all — skipped.
                  ("broken-entry", Json::number(42.0)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    ]),
  )
}

///|
test "parse_models_dev_surfaces decodes levels, toggles, and degraded shapes" {
  let surfaces = parse_models_dev_surfaces(models_dev_sample_payload())
  inspect(surfaces.length(), content="10")
  // gpt-5.1: levels pass through verbatim, "none" included; "none" in the
  // levels makes the model disableable even without a toggle option.
  guard surfaces.get("gpt-5.1") is Some(gpt) else {
    fail("expected a surface for gpt-5.1")
  }
  assert_true(gpt.reasoning)
  debug_inspect(
    gpt.levels,
    content=(
      #|["none", "low", "medium", "high"]
    ),
  )
  assert_true(gpt.can_disable)
  // kimi-k2.5: toggle only — disableable, no levels.
  guard surfaces.get("kimi-k2.5") is Some(kimi) else {
    fail("expected a surface for kimi-k2.5")
  }
  assert_true(kimi.reasoning)
  assert_true(kimi.levels.is_empty())
  assert_true(kimi.can_disable)
  // deepseek-v4-flash: toggle plus effort levels.
  guard surfaces.get("deepseek-v4-flash") is Some(deepseek) else {
    fail("expected a surface for deepseek-v4-flash")
  }
  debug_inspect(
    deepseek.levels,
    content=(
      #|["low", "high", "max"]
    ),
  )
  assert_true(deepseek.can_disable)
  // claude-3-5-haiku: plain chat.
  guard surfaces.get("claude-3-5-haiku") is Some(haiku) else {
    fail("expected a surface for claude-3-5-haiku")
  }
  assert_true(haiku.reasoning == false)
  assert_true(haiku.levels.is_empty())
  assert_true(haiku.can_disable == false)
  // claude-haiku-4-5: budget tokens carry no selectable levels.
  guard surfaces.get("claude-haiku-4-5") is Some(budget) else {
    fail("expected a surface for claude-haiku-4-5")
  }
  assert_true(budget.reasoning)
  assert_true(budget.levels.is_empty())
  assert_true(budget.can_disable == false)
  // union-alpha and the missing-options model: reasoning without levels.
  guard surfaces.get("union-alpha") is Some(union) else {
    fail("expected a surface for union-alpha")
  }
  assert_true(union.reasoning)
  assert_true(union.levels.is_empty())
  assert_true(union.can_disable == false)
  guard surfaces.get("no-options-model") is Some(no_options) else {
    fail("expected a surface for no-options-model")
  }
  assert_true(no_options.reasoning)
  assert_true(no_options.levels.is_empty())
  // Null effort values map to the "none" level name.
  guard surfaces.get("null-level-model") is Some(null_level) else {
    fail("expected a surface for null-level-model")
  }
  debug_inspect(
    null_level.levels,
    content=(
      #|["none", "high"]
    ),
  )
  assert_true(null_level.can_disable)
  // Unknown option types and non-array options degrade to no levels.
  guard surfaces.get("mystery-option-model") is Some(mystery) else {
    fail("expected a surface for mystery-option-model")
  }
  assert_true(mystery.levels.is_empty())
  assert_true(mystery.can_disable == false)
  guard surfaces.get("junk-options-model") is Some(junk) else {
    fail("expected a surface for junk-options-model")
  }
  assert_true(junk.reasoning)
  assert_true(junk.levels.is_empty())
  // The malformed model entry is skipped, not fatal.
  assert_true(surfaces.get("broken-entry") is None)
}

///|
test "parse_models_dev_surfaces rejects payloads without the opencode models" {
  let bad_roots : Array[Json] = [
    Json::array([]),
    Json::string("not-an-object"),
    Json::object(
      Map::from_array([("other", Json::object(Map::from_array([])))]),
    ),
    Json::object(
      Map::from_array([("opencode", Json::object(Map::from_array([])))]),
    ),
    Json::object(
      Map::from_array([
        (
          "opencode",
          Json::object(Map::from_array([("models", Json::string("oops"))])),
        ),
      ]),
    ),
  ]
  for payload in bad_roots {
    let result = Ok(parse_models_dev_surfaces(payload)) catch {
      error => Err(error)
    }
    match result {
      Err(@posoco.ModelError::ResponseParse(msg)) =>
        assert_true(msg.contains("models.dev"))
      _ =>
        fail("expected ResponseParse naming models.dev for a bad payload root")
    }
  }
}

///|
/// Build a base config used by the multi-slot catalog tests.
fn zen_base_config() -> OpenCodeZenConfig {
  OpenCodeZenConfig(
    "sk-test",
    base_url="https://opencode.ai/zen/v1",
    model="gpt-5.1-codex",
  )
}

///|
test "zen_model_catalog builds one slot per discovered model" {
  let provider = OpenCodeZenProvider()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let models = parse_zen_models(zen_sample_models_payload())
  let catalog = zen_model_catalog(
    zen_base_config(),
    models,
    "gpt-5.1-codex",
    Map::from_array([]),
    api_key_factory,
  )
  assert_eq(catalog.provider_id, "opencode")
  let slots = catalog.slots()
  inspect(slots.length(), content="3")
  // Configured model is pinned first.
  assert_eq(slots[0].model_id, "gpt-5.1-codex")
  // Slot id is provider-qualified.
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
  // Every slot carries the Zen display group and chat capability.
  assert_true(slots.every(slot => slot.display_group == Some("zen")))
  assert_true(slots.every(slot => slot.capabilities.contains("chat")))
}

///|
test "zen_model_catalog raises on an empty model list" {
  let provider = OpenCodeZenProvider()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let result = Ok(
    zen_model_catalog(
      zen_base_config(),
      [],
      "any",
      Map::from_array([]),
      api_key_factory,
    ),
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
  let provider = OpenCodeZenProvider()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let models = parse_zen_models(zen_sample_models_payload())
  // No model matches "nonexistent" → original order preserved.
  let catalog = zen_model_catalog(
    zen_base_config(),
    models,
    "nonexistent",
    Map::from_array([]),
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
  let provider = OpenCodeZenProvider()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let catalog = zen_static_catalog(zen_base_config(), api_key_factory)
  let slots = catalog.slots()
  assert_true(slots.length() == 1)
  assert_eq(slots[0].model_id, "gpt-5.1-codex")
  assert_eq(slots[0].id, "opencode/gpt-5.1-codex")
}

///|
test "OpenCodeZenProvider reports the opencode provider and credential id" {
  let provider = OpenCodeZenProvider()
  let factory : &@llm.ProviderFactory = provider
  assert_eq(factory.provider_id(), "opencode")
  assert_eq(factory.credential_id(), "opencode")
}

///|
test "ProviderFactory::build returns Unconfigured without any api key" {
  let provider = OpenCodeZenProvider()
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
  let provider = OpenCodeZenProvider()
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
  let provider = OpenCodeZenProvider()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(zen_settings([("api_key", "sk-zen-test")])),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      // The static-build default model is observable on the slot; the base
      // URL flows into the port's private config and is not re-exposed here.
      assert_eq(slot.model_id, "claude-sonnet-5")
      assert_eq(slot.id, "opencode/claude-sonnet-5")
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with defaults applied")
  }
}

///|
test "ProviderFactory::build prefers api_key credential over the setting" {
  let provider = OpenCodeZenProvider()
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
/// records. Zen consumes `model_id` and the cached `thinking_efforts` picker;
/// extra fields ride along untouched.
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
  let provider = OpenCodeZenProvider()
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
  let provider = OpenCodeZenProvider()
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
  let provider = OpenCodeZenProvider()
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
  let provider = OpenCodeZenProvider()
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = ZenApiKeyPrompt::{ value: "sk-via-login", }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let credential = api.login(prompt)
  assert_eq(credential.secret, "sk-via-login")
}

///|
async test "ApiKeyFactory::login rejects an empty secret" {
  let provider = OpenCodeZenProvider()
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = ZenApiKeyPrompt::{ value: "", }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let result = Ok(api.login(prompt)) catch { error => Err(error) }
  match result {
    Err(@oauth.OAuthError::ParseError(message)) =>
      assert_true(message.contains("must not be empty"))
    _ => fail("expected empty API key to fail")
  }
}

///|
/// Build a reasoning surface for mapping probes.
fn zen_surface(
  reasoning~ : Bool,
  levels~ : Array[String],
  can_disable~ : Bool,
) -> ZenReasoningSurface {
  { reasoning, levels, can_disable, }
}

///|
/// Build one slot over a probe surface, pairing config and slot exactly as
/// the catalog builders do.
fn zen_surface_slot(
  surface : ZenReasoningSurface?,
  provider : OpenCodeZenProvider,
) -> @llm.ModelSlot {
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let config = zen_config_for_model(zen_base_config(), "probe-model", surface)
  zen_catalog_slot(config, surface, api_key_factory)
}

///|
test "zen slot mapping covers all reasoning surface shapes" {
  let provider = OpenCodeZenProvider()
  // Unknown surface (metadata missing or the models.dev fetch degraded):
  // safe off/on toggle with thinking off, default off, rebuildable.
  let unknown = zen_surface_slot(None, provider)
  debug_inspect(
    unknown.thinking_efforts,
    content=(
      #|["off", "on"]
    ),
  )
  assert_eq(unknown.default_effort, Some("off"))
  guard unknown.rebuild_on_effort is Some(unknown_rebuild) else {
    fail("expected a rebuild hook for the off/on fallback")
  }
  assert_eq(unknown_rebuild("on").default_effort, Some("on"))
  // Plain chat model: no selector at all.
  let chat = zen_surface_slot(
    Some(zen_surface(reasoning=false, levels=[], can_disable=false)),
    provider,
  )
  debug_inspect(
    chat.thinking_efforts,
    content=(
      #|[]
    ),
  )
  assert_eq(chat.default_effort, None)
  assert_true(chat.rebuild_on_effort is None)
  // Reasoning model without declared levels: bare off/on toggle.
  let toggle = zen_surface_slot(
    Some(zen_surface(reasoning=true, levels=[], can_disable=true)),
    provider,
  )
  debug_inspect(
    toggle.thinking_efforts,
    content=(
      #|["off", "on"]
    ),
  )
  assert_eq(toggle.default_effort, Some("off"))
  // Level-bearing model that cannot be disabled: levels only, "high" wins
  // the default.
  let levels = zen_surface_slot(
    Some(zen_surface(reasoning=true, levels=["low", "high"], can_disable=false)),
    provider,
  )
  debug_inspect(
    levels.thinking_efforts,
    content=(
      #|["low", "high"]
    ),
  )
  assert_eq(levels.default_effort, Some("high"))
  // Level-bearing model without "high": the first declared level starts.
  let maxed = zen_surface_slot(
    Some(zen_surface(reasoning=true, levels=["max"], can_disable=false)),
    provider,
  )
  debug_inspect(
    maxed.thinking_efforts,
    content=(
      #|["max"]
    ),
  )
  assert_eq(maxed.default_effort, Some("max"))
  // Disableable level-bearing model: "off" prefixes the levels.
  let disableable = zen_surface_slot(
    Some(zen_surface(reasoning=true, levels=["low", "high"], can_disable=true)),
    provider,
  )
  debug_inspect(
    disableable.thinking_efforts,
    content=(
      #|["off", "low", "high"]
    ),
  )
  assert_eq(disableable.default_effort, Some("high"))
}

///|
test "zen_model_catalog applies models.dev surfaces end to end" {
  let provider = OpenCodeZenProvider()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let surfaces = parse_models_dev_surfaces(models_dev_sample_payload())
  // Real gpt-5.1 sample: effort values ["none","low","medium","high"] with
  // no toggle — "none" in the levels contributes the "off" entry.
  let gpt_models = [
    ZenModelInfo::{ id: "gpt-5.1", owned_by: "opencode", cached_efforts: [], },
  ]
  let gpt_catalog = zen_model_catalog(
    zen_base_config(),
    gpt_models,
    "gpt-5.1",
    surfaces,
    api_key_factory,
  )
  let gpt_slot = gpt_catalog.slots()[0]
  debug_inspect(
    gpt_slot.thinking_efforts,
    content=(
      #|["off", "none", "low", "medium", "high"]
    ),
  )
  assert_eq(gpt_slot.default_effort, Some("high"))
  // Deepseek sample: toggle plus levels.
  let deepseek_models = [
    ZenModelInfo::{
      id: "deepseek-v4-flash",
      owned_by: "opencode",
      cached_efforts: [],
    },
  ]
  let deepseek_catalog = zen_model_catalog(
    zen_base_config(),
    deepseek_models,
    "deepseek-v4-flash",
    surfaces,
    api_key_factory,
  )
  let deepseek_slot = deepseek_catalog.slots()[0]
  debug_inspect(
    deepseek_slot.thinking_efforts,
    content=(
      #|["off", "low", "high", "max"]
    ),
  )
  assert_eq(deepseek_slot.default_effort, Some("high"))
  // Plain chat model: no selector at all.
  let chat_models = [
    ZenModelInfo::{
      id: "claude-3-5-haiku",
      owned_by: "opencode",
      cached_efforts: [],
    },
  ]
  let chat_catalog = zen_model_catalog(
    zen_base_config(),
    chat_models,
    "claude-3-5-haiku",
    surfaces,
    api_key_factory,
  )
  assert_true(chat_catalog.slots()[0].thinking_efforts.is_empty())
}

///|
test "zen_model_catalog degrades to the off/on picker with an empty surface map" {
  let provider = OpenCodeZenProvider()
  let api_key_factory : &@llm.ApiKeyFactory = provider
  let models = parse_zen_models(zen_sample_models_payload())
  let catalog = zen_model_catalog(
    zen_base_config(),
    models,
    "gpt-5.1-codex",
    Map::from_array([]),
    api_key_factory,
  )
  for slot in catalog.slots() {
    debug_inspect(
      slot.thinking_efforts,
      content=(
        #|["off", "on"]
      ),
    )
    assert_eq(slot.default_effort, Some("off"))
  }
}

///|
test "zen slot rebuild_on_effort reselects levels and toggles off" {
  let provider = OpenCodeZenProvider()
  let surface = zen_surface(
    reasoning=true,
    levels=["low", "medium", "high"],
    can_disable=true,
  )
  let slot = zen_surface_slot(Some(surface), provider)
  assert_eq(slot.default_effort, Some("high"))
  guard slot.rebuild_on_effort is Some(rebuild) else {
    fail("expected a rebuild hook for a level-bearing model")
  }
  let lowered = rebuild("medium")
  assert_eq(lowered.default_effort, Some("medium"))
  debug_inspect(
    lowered.thinking_efforts,
    content=(
      #|["off", "low", "medium", "high"]
    ),
  )
  let offed = rebuild("off")
  assert_eq(offed.default_effort, Some("off"))
}

///|
test "zen cached surface rebuilds levels from the cached picker" {
  let provider = OpenCodeZenProvider()
  // The host cache stores the previous refresh's full picker: "off" marks a
  // disableable model, "on" is toggle residue, everything else is a level.
  let level_surface = zen_cached_surface(ZenModelInfo::{
    id: "x",
    owned_by: "",
    cached_efforts: ["off", "low", "high"],
  })
  guard level_surface is Some(level) else {
    fail("expected a surface from a level-bearing picker")
  }
  debug_inspect(
    level.levels,
    content=(
      #|["low", "high"]
    ),
  )
  assert_true(level.can_disable)
  let level_slot = zen_surface_slot(level_surface, provider)
  debug_inspect(
    level_slot.thinking_efforts,
    content=(
      #|["off", "low", "high"]
    ),
  )
  assert_eq(level_slot.default_effort, Some("high"))
  // A bare off/on cache entry carries no levels.
  let toggle_surface = zen_cached_surface(ZenModelInfo::{
    id: "x",
    owned_by: "",
    cached_efforts: ["off", "on"],
  })
  guard toggle_surface is Some(toggle) else {
    fail("expected a surface from an off/on picker")
  }
  assert_true(toggle.levels.is_empty())
  let toggle_slot = zen_surface_slot(toggle_surface, provider)
  debug_inspect(
    toggle_slot.thinking_efforts,
    content=(
      #|["off", "on"]
    ),
  )
  // No cached efforts at all: no surface, the off/on fallback applies.
  assert_true(
    zen_cached_surface(ZenModelInfo::{
      id: "x",
      owned_by: "",
      cached_efforts: [],
    })
    is None,
  )
}

///|
test "zen cached records parse with their thinking_efforts picker" {
  let records = Json::array([
    Json::object(
      Map::from_array([
        ("model_id", Json::string("x")),
        (
          "thinking_efforts",
          Json::array([Json::string("off"), Json::string("high")]),
        ),
      ]),
    ),
    // No thinking_efforts field: tolerated as an empty picker.
    Json::object(Map::from_array([("model_id", Json::string("y"))])),
  ])
  guard parse_cached_zen_models(Some(records)) is Some(models) else {
    fail("expected cached models")
  }
  assert_eq(models.length(), 2)
  debug_inspect(
    models[0].cached_efforts,
    content=(
      #|["off", "high"]
    ),
  )
  assert_true(models[1].cached_efforts.is_empty())
}

///|
test "ProviderFactory::build rebuilds level pickers from cached thinking_efforts" {
  let provider = OpenCodeZenProvider()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      zen_settings([("api_key", "sk-zen-test"), ("model", "gpt-5.1-codex")]),
    ),
    cached_models=Some(
      Json::array([
        Json::object(
          Map::from_array([
            ("model_id", Json::string("gpt-5.1-codex")),
            (
              "thinking_efforts",
              Json::array([
                Json::string("off"),
                Json::string("low"),
                Json::string("high"),
              ]),
            ),
          ]),
        ),
        Json::object(
          Map::from_array([("model_id", Json::string("claude-plain"))]),
        ),
      ]),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slots = catalog.slots()
      assert_eq(slots.length(), 2)
      // The cached picker minus off/on becomes the declared levels; "off"
      // re-joins because the cached picker contained it.
      debug_inspect(
        slots[0].thinking_efforts,
        content=(
          #|["off", "low", "high"]
        ),
      )
      assert_eq(slots[0].default_effort, Some("high"))
      // No cached efforts: the off/on fallback with thinking off.
      debug_inspect(
        slots[1].thinking_efforts,
        content=(
          #|["off", "on"]
        ),
      )
      assert_eq(slots[1].default_effort, Some("off"))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog from cached records")
  }
}

///|
/// Flaky inner port: raises `error` until `failures_left` is exhausted, then
/// answers with an empty stop completion.
struct FlakyModelPort {
  calls : Ref[Int]
  failures_left : Ref[Int]
  error : @posoco.ModelError
}

///|
fn FlakyModelPort::FlakyModelPort(
  failures : Int,
  error : @posoco.ModelError,
) -> FlakyModelPort {
  FlakyModelPort::{
    calls: Ref::{ val: 0, },
    failures_left: Ref::{ val: failures, },
    error,
  }
}

///|
impl @posoco.ModelPort for FlakyModelPort with fn chat(
  self : FlakyModelPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.calls.val += 1
  if self.failures_left.val > 0 {
    self.failures_left.val -= 1
    raise self.error
  }
  @posoco.ModelCallResult::{
    completion: @posoco.Completion::Completion(
      content=[],
      tool_calls=[],
      reasoning=None,
      finish_reason=@posoco.FinishReason::Stop,
      usage=None,
    ),
    processed_messages: [],
  }
}

///|
impl @posoco.ModelPort for FlakyModelPort with fn compact(
  self : FlakyModelPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  self.calls.val += 1
  if self.failures_left.val > 0 {
    self.failures_left.val -= 1
    raise self.error
  }
  @posoco.CompactResult::{
    compacted_messages: [],
    mode: @posoco.CompactMode::Replace,
  }
}

///|
impl @posoco.ModelPort for FlakyModelPort with fn provider_config(
  _self : FlakyModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
fn zen_flaky_scope() -> @posoco.InvocationScope {
  @posoco.InvocationScope::{
    session_id: @posoco.SessionId::unchecked("zen-retry-test"),
    run_id: @posoco.RunId::unchecked("run-1"),
    effect_id: None,
    pressure: None,
  }
}

///|
fn zen_flaky_options() -> @posoco.ChatOptions {
  @posoco.ChatOptions::{ temperature: None, max_output_tokens: None, }
}

///|
fn zen_truncated_error() -> @posoco.ModelError {
  @posoco.ModelError::ResponseParse(
    "opencode-zen SSE truncated (stage=eof, terminal_marker=missing)",
  )
}

///|
fn zen_gateway_503_error() -> @posoco.ModelError {
  @posoco.ModelError::Transport(
    "opencode-zen HTTP error (stage=chat_stream.http_status, status=503, body_bytes=175, body_category=utf8)",
  )
}

///|
async test "zen retry port retries truncated SSE failures until success" {
  let inner = FlakyModelPort(2, zen_truncated_error())
  let port : &@posoco.ModelPort = zen_test_retry_port(inner)
  let result = port.chat(
    zen_flaky_scope(),
    [],
    [],
    zen_flaky_options(),
    @posoco.StreamMode::NoStream,
  )
  assert_eq(result.completion.message.finish_reason, @posoco.FinishReason::Stop)
  assert_eq(inner.calls.val, 3)
}

///|
async test "zen retry port gives up after the retry budget" {
  let inner = FlakyModelPort(99, zen_truncated_error())
  let port : &@posoco.ModelPort = zen_test_retry_port(inner)
  let result = Ok(
    port.chat(
      zen_flaky_scope(),
      [],
      [],
      zen_flaky_options(),
      @posoco.StreamMode::NoStream,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(_) => fail("expected the truncation error after the retry budget")
    Err(error) => assert_true(zen_retryable_error(error))
  }
  // 1 initial attempt + 3 retries.
  assert_eq(inner.calls.val, 4)
}

///|
async test "zen retry port does not retry other model errors" {
  let inner = FlakyModelPort(
    1,
    @posoco.ModelError::Transport("connection reset"),
  )
  let port : &@posoco.ModelPort = zen_test_retry_port(inner)
  let result = Ok(
    port.chat(
      zen_flaky_scope(),
      [],
      [],
      zen_flaky_options(),
      @posoco.StreamMode::NoStream,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(_) => fail("expected the transport error to surface unretried")
    Err(_) => ()
  }
  assert_eq(inner.calls.val, 1)
}

///|
/// Inner port for compact-retry tests: raises the given error until
/// `failures_left` is exhausted, then answers with a completion carrying
/// the summary text (an empty stop completion would fail the compact with
/// the typed empty-summary error instead).
struct ZenSummaryModelPort {
  calls : Ref[Int]
  failures_left : Ref[Int]
  error : @posoco.ModelError
  summary : String
}

///|
fn ZenSummaryModelPort::ZenSummaryModelPort(
  failures : Int,
  error : @posoco.ModelError,
  summary : String,
) -> ZenSummaryModelPort {
  ZenSummaryModelPort::{
    calls: Ref::{ val: 0, },
    failures_left: Ref::{ val: failures, },
    error,
    summary,
  }
}

///|
impl @posoco.ModelPort for ZenSummaryModelPort with fn chat(
  self : ZenSummaryModelPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.calls.val += 1
  if self.failures_left.val > 0 {
    self.failures_left.val -= 1
    raise self.error
  }
  let completion = @posoco.Completion::Completion(
    content=[@posoco.Content::Text(self.summary)],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=None,
  )
  @posoco.ModelCallResult::{ completion, processed_messages: [], }
}

///|
impl @posoco.ModelPort for ZenSummaryModelPort with fn compact(
  _self : ZenSummaryModelPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  abort("zen compact no longer forwards to the inner port")
}

///|
impl @posoco.ModelPort for ZenSummaryModelPort with fn provider_config(
  _self : ZenSummaryModelPort,
) -> @posoco.ProviderConfig {
  // 28k window -> keep_recent = 2000 (quarter of the 8k usable), so short
  // test transcripts still produce a nonempty head to summarize.
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=Some(28_000),
  )
}

///|
async test "zen retry port retries truncated SSE during compact" {
  let inner = ZenSummaryModelPort::ZenSummaryModelPort(
    1,
    zen_truncated_error(),
    "anchored summary text",
  )
  let port : &@posoco.ModelPort = zen_test_retry_port(inner)
  // Two ~2500-token turns: the keep-recent walk stops at the second long
  // turn (a safe user boundary), leaving the first turn as a nonempty head.
  let long_history = "detail ".repeat(1200)
  let messages = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text(long_history)]),
    @posoco.Message::AssistantMessage(
      content=[@posoco.Content::Text("first answer")],
      tool_calls=[],
      reasoning=None,
      finish_reason=@posoco.FinishReason::Stop,
    ),
    @posoco.Message::UserMessage(content=[@posoco.Content::Text(long_history)]),
    @posoco.Message::AssistantMessage(
      content=[@posoco.Content::Text("second answer")],
      tool_calls=[],
      reasoning=None,
      finish_reason=@posoco.FinishReason::Stop,
    ),
  ]
  let result = port.compact(
    zen_flaky_scope(),
    messages[:],
    zen_flaky_options(),
    @posoco.CompactTrigger::Manual,
  )
  assert_true(result.mode == @posoco.CompactMode::Replace)
  // 1 failed summarize attempt + 1 successful retry.
  assert_eq(inner.calls.val, 2)
}

///|
/// Zero-delay retry wrapper so tests don't wait out the backoff.
fn zen_test_retry_port(inner : &@posoco.ModelPort) -> &@posoco.ModelPort {
  ZenRetryModelPort::{
    inner,
    max_retries: zen_max_retries,
    initial_delay_ms: 0,
  }
}

///|
async test "zen retry port retries mid-stream transport failures" {
  let inner = FlakyModelPort(
    1,
    @posoco.ModelError::Transport(
      "opencode-zen transport failure (stage=read_stream)",
    ),
  )
  let port : &@posoco.ModelPort = zen_test_retry_port(inner)
  let result = port.chat(
    zen_flaky_scope(),
    [],
    [],
    zen_flaky_options(),
    @posoco.StreamMode::NoStream,
  )
  assert_eq(result.completion.message.finish_reason, @posoco.FinishReason::Stop)
  assert_eq(inner.calls.val, 2)
}

///|
async test "zen retry port does not retry pre-stream transport failures" {
  let inner = FlakyModelPort(
    1,
    @posoco.ModelError::Transport("opencode-zen transport failure (stage=post)"),
  )
  let port : &@posoco.ModelPort = zen_test_retry_port(inner)
  let result = Ok(
    port.chat(
      zen_flaky_scope(),
      [],
      [],
      zen_flaky_options(),
      @posoco.StreamMode::NoStream,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(_) => fail("expected the stage=post error to surface unretried")
    Err(_) => ()
  }
  assert_eq(inner.calls.val, 1)
}

///|
async test "zen retry port retries gateway 503 responses until success" {
  let inner = FlakyModelPort(2, zen_gateway_503_error())
  let port : &@posoco.ModelPort = zen_test_retry_port(inner)
  let result = port.chat(
    zen_flaky_scope(),
    [],
    [],
    zen_flaky_options(),
    @posoco.StreamMode::NoStream,
  )
  assert_eq(result.completion.message.finish_reason, @posoco.FinishReason::Stop)
  assert_eq(inner.calls.val, 3)
}

///|
async test "zen retry port does not retry other http statuses" {
  let inner = FlakyModelPort(
    1,
    @posoco.ModelError::Transport(
      "opencode-zen HTTP error (stage=chat_stream.http_status, status=400, body=bad request)",
    ),
  )
  let port : &@posoco.ModelPort = zen_test_retry_port(inner)
  let result = Ok(
    port.chat(
      zen_flaky_scope(),
      [],
      [],
      zen_flaky_options(),
      @posoco.StreamMode::NoStream,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(_) => fail("expected the 400 error to surface unretried")
    Err(_) => ()
  }
  assert_eq(inner.calls.val, 1)
}

///|
test "zen_keep_recent_tokens clamps the opencode quarter-of-usable budget" {
  // Unknown window → 15k ceiling fallback.
  assert_eq(zen_keep_recent_tokens(None), 15_000)
  // Window too small to reserve from → fallback.
  assert_eq(zen_keep_recent_tokens(Some(20_000)), 15_000)
  // quarter of usable (80k) = 20k, above the 15k ceiling.
  assert_eq(zen_keep_recent_tokens(Some(100_000)), 15_000)
  // quarter of usable (60k) = 15k, exactly the ceiling.
  assert_eq(zen_keep_recent_tokens(Some(80_000)), 15_000)
  // quarter of usable (30k) = 7.5k, within the clamp.
  assert_eq(zen_keep_recent_tokens(Some(50_000)), 7_500)
  // quarter below floor.
  assert_eq(zen_keep_recent_tokens(Some(24_000)), 2_000)
  // quarter above ceiling.
  assert_eq(zen_keep_recent_tokens(Some(200_000)), 15_000)
}

///|
test "zen_previous_summary extracts the latest anchored summary stripped" {
  let prefix = @compact_summary.SUMMARY_PREFIX
  let head = [
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Text(prefix + "\n\nfirst summary"),
    ]),
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("plain")]),
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Text(prefix + "\n\nsecond summary"),
    ]),
  ]
  guard zen_previous_summary(head) is Some(text) else {
    fail("expected a previous summary")
  }
  assert_true(text.contains("second summary"))
  // No summary present → None.
  assert_true(zen_previous_summary([]) is None)
}

///|
fn zen_user_msg(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
/// Build a request body and assert the GLM-flavored reasoning wire contract:
/// thinking off omits `thinking`/`reasoning_effort` entirely; thinking on
/// sends the object form `thinking: {"type": "enabled"}` (never a bare
/// boolean — Zen's upstream rejects it); a selected level additionally sends
/// the top-level `reasoning_effort` verbatim.
test "zen wire sends the GLM thinking object and verbatim reasoning_effort" {
  let opts = zen_flaky_options()
  let with_effort = build_chat_request(
    [zen_user_msg("hi")],
    [],
    opts,
    "glm-5.2",
    false,
    true,
    Some("low"),
    false,
  )
  guard with_effort is Object(with_fields) else {
    fail("expected request to be an object")
  }
  match with_fields.get("thinking") {
    Some(Json::Object(thinking)) =>
      match thinking.get("type") {
        Some(Json::String("enabled")) => ()
        _ => fail("expected thinking object with type=enabled")
      }
    _ => fail("expected the thinking object when a level is selected")
  }
  match with_fields.get("reasoning_effort") {
    Some(Json::String(value)) => assert_eq(value, "low")
    _ => fail("expected reasoning_effort to be emitted when a level is set")
  }

  let toggle_on = build_chat_request(
    [zen_user_msg("hi")],
    [],
    opts,
    "glm-5.2",
    false,
    true,
    None,
    false,
  )
  guard toggle_on is Object(on_fields) else {
    fail("expected request to be an object")
  }
  match on_fields.get("thinking") {
    Some(Json::Object(thinking)) =>
      match thinking.get("type") {
        Some(Json::String("enabled")) => ()
        _ => fail("expected thinking object with type=enabled")
      }
    _ => fail("expected the thinking object in plain toggle mode")
  }
  match on_fields.get("reasoning_effort") {
    None => ()
    Some(_) => fail("reasoning_effort must be omitted without a level")
  }

  let toggle_off = build_chat_request(
    [zen_user_msg("hi")],
    [],
    opts,
    "glm-5.2",
    false,
    false,
    None,
    false,
  )
  guard toggle_off is Object(off_fields) else {
    fail("expected request to be an object")
  }
  match off_fields.get("thinking") {
    None => ()
    Some(_) => fail("thinking must be omitted entirely when off")
  }
  match off_fields.get("reasoning_effort") {
    None => ()
    Some(_) => fail("reasoning_effort must be omitted when off")
  }
}

///|
/// Thinking-mode upstreams behind Zen (DeepSeek) 400 unless the assistant
/// message resends `reasoning_content`; zen's policy is keep-all — resent
/// whenever reasoning is present, with or without tool_calls.
test "zen wire keeps reasoning_content on assistant messages (keep-all)" {
  let with_calls : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[],
    tool_calls=[
      {
        call_id: @posoco.CallId::unchecked("c1"),
        name: @posoco.ToolName::unchecked("read"),
        arguments: Json::object(Map::from_array([])),
      },
    ],
    reasoning=Some(@posoco.Reasoning::{
      content: "thinking about this...",
      raw: None,
    }),
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  guard encode_message(with_calls, false) is Object(with_obj) else {
    fail("expected object")
  }
  match with_obj.get("reasoning_content") {
    Some(String(r)) => assert_eq(r, "thinking about this...")
    _ => fail("reasoning_content MUST be present when tool_calls exist")
  }

  let without_calls : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=Some(@posoco.Reasoning::{ content: "thinking...", raw: None, }),
    finish_reason=@posoco.FinishReason::Stop,
  )
  guard encode_message(without_calls, false) is Object(plain_obj) else {
    fail("expected object")
  }
  match plain_obj.get("reasoning_content") {
    Some(String(r)) => assert_eq(r, "thinking...")
    _ => fail("reasoning_content must be preserved on assistant messages")
  }
}

///|
/// Streaming requests always opt into usage accounting — without
/// `stream_options.include_usage` the gateway omits the usage frame entirely.
test "zen wire opts into stream usage accounting" {
  let tool = @posoco.ToolDef::ToolDef(
    name=@posoco.ToolName::unchecked("echo"),
    description="echo back",
    input_schema=Json::object(Map::from_array([])),
    owner=@posoco.OwnerId::unchecked("test"),
    policy=@posoco.ExecutionPolicy::Sequential,
    provenance=None,
  )
  let body = build_chat_request(
    [zen_user_msg("hi")],
    [tool],
    zen_flaky_options(),
    "glm-5.2",
    true,
    false,
    None,
    false,
  )
  guard body is Object(fields) else { fail("expected object body") }
  match fields.get("stream") {
    Some(value) => assert_eq(value.stringify(), "true")
    None => fail("expected stream field")
  }
  match fields.get("stream_options") {
    Some(Json::Object(opts)) =>
      match opts.get("include_usage") {
        Some(value) => assert_eq(value.stringify(), "true")
        None => fail("expected include_usage for usage accounting")
      }
    _ => fail("expected stream_options for usage accounting")
  }
}

///|
test "zen_cancelled_transport_marks_cancellation" {
  let err = zen_cancelled_transport("read_stream")
  guard err is @posoco.ModelError::Transport(message) else {
    fail("expected a Transport error")
  }
  assert_eq(
    message, "opencode-zen transport failure (stage=read_stream, category=cancelled)",
  )
}
