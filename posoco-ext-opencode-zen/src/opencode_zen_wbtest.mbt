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
  // No model matches "nonexistent" → original order preserved.
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
