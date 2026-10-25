///|
/// White-box tests for the typesafe ProviderFactory / ApiKeyFactory seams:
/// catalog shape, credential precedence, and explicit login failure.

///|
priv struct ScriptedPrompt {
  response : String
}

///|
impl @oauth.AuthPromptInteraction for ScriptedPrompt with fn prompt(
  self : ScriptedPrompt,
  _request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  self.response
}

///|
priv struct CancelledPrompt {}

///|
impl @oauth.AuthPromptInteraction for CancelledPrompt with fn prompt(
  _self : CancelledPrompt,
  _request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  raise @oauth.OAuthError::Cancelled
}

///|
fn api_key_credential(secret : String) -> @oauth.ProviderCredential {
  @oauth.ProviderCredential::ApiKey(
    @oauth.ApiKeyCredential::ApiKeyCredential(secret~),
  )
}

///|
fn settings_source(
  settings~ : Array[(String, Json)] = [],
  provider_credential~ : @oauth.ProviderCredential? = None,
  store~ : &@oauth.ProviderCredentialStore? = None,
) -> @provider.ProviderConfigSource {
  @provider.ProviderConfigSource::ProviderConfigSource(
    settings=Some(Json::object(Map::from_array(settings))),
    provider_credential~,
    credential_store=store,
  )
}

///|
test "typesafe factory claims the canonical provider and credential ids" {
  let factory : &@provider.ProviderFactory = TypesafeProvider::{ }
  assert_eq(factory.provider_id(), "typesafe")
  assert_eq(factory.credential_id(), "typesafe")
  let api_key : &@provider.ApiKeyFactory = TypesafeProvider::{ }
  assert_eq(api_key.provider_id(), "typesafe")
  assert_eq(api_key.credential_id(), "typesafe")
}

///|
test "typesafe build is unconfigured without credential or settings key" {
  let result = TypesafeProvider::{ }.build(settings_source())
  assert_true(result is @provider.ProviderBuildResult::Unconfigured)
}

///|
test "typesafe build yields a decision-only jev catalog from a stored key" {
  let result = TypesafeProvider::{ }.build(
    settings_source(provider_credential=Some(api_key_credential("stored"))),
  )
  guard result is @provider.ProviderBuildResult::Ready(catalog) else {
    fail("expected a ready catalog")
  }
  assert_eq(catalog.provider_id(), "typesafe")
  assert_true(catalog.auth_methods().contains(@provider.AuthMethod::ApiKey))
  let slots = catalog.slots()
  assert_eq(slots.length(), 1)
  let slot = slots[0]
  assert_eq(slot.id, "typesafe/jev-latest")
  assert_eq(slot.provider_id, "typesafe")
  assert_eq(slot.model_id, "jev-latest")
  assert_true(slot.is_decision())
  assert_false(slot.is_chat())
  assert_true(slot.decision_port is Some(_))
  assert_true(slot.api_key is Some(_))
}

///|
test "typesafe build falls back to the settings api_key without a record" {
  let result = TypesafeProvider::{ }.build(
    settings_source(settings=[("api_key", Json::string("settings-key"))]),
  )
  guard result is @provider.ProviderBuildResult::Ready(catalog) else {
    fail("expected a ready catalog")
  }
  assert_eq(catalog.slots().length(), 1)
}

///|
test "typesafe stored credential wins over the settings api_key" {
  let config = typesafe_provider_config(
    settings_source(
      settings=[("api_key", Json::string("settings-key"))],
      provider_credential=Some(api_key_credential("stored-key")),
    ),
  )
  guard config is Some(resolved) else { fail("expected a config") }
  assert_eq(resolved.api_key, "stored-key")
}

///|
test "typesafe settings model and base_url flow into the catalog" {
  let result = TypesafeProvider::{ }.build(
    settings_source(settings=[
      ("api_key", Json::string("settings-key")),
      ("model", Json::string("jev-latest")),
      ("base_url", Json::string("https://jev.example.ai")),
    ]),
  )
  guard result is @provider.ProviderBuildResult::Ready(catalog) else {
    fail("expected a ready catalog")
  }
  let slot = catalog.slots()[0]
  assert_eq(slot.id, "typesafe/jev-latest")
  assert_eq(slot.model_id, "jev-latest")
}

///|
test "typesafe build rejects a stored OAuth credential and an empty stored key" {
  let oauth = Ok(
    TypesafeProvider::{ }.build(
      settings_source(
        provider_credential=Some(
          @oauth.ProviderCredential::OAuth(
            @oauth.Credential::Credential(
              access_token="token",
              refresh_token="refresh",
              expires_at=0,
            ),
          ),
        ),
      ),
    ),
  ) catch {
    err => Err(err)
  }
  match oauth {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("must be an API key"))
    _ => fail("an OAuth record must fail composition loudly")
  }
  let empty = Ok(
    TypesafeProvider::{ }.build(
      settings_source(provider_credential=Some(api_key_credential("  "))),
    ),
  ) catch {
    err => Err(err)
  }
  match empty {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("empty"))
    _ => fail("an empty stored key must fail composition loudly")
  }
}

///|
async test "typesafe api_key login returns the prompted secret" {
  let credential = TypesafeProvider::{ }.login(
    ScriptedPrompt::{ response: "sk-jev", } as &@oauth.AuthPromptInteraction,
  )
  assert_eq(credential.secret, "sk-jev")
}

///|
async test "typesafe api_key login rejects an empty secret explicitly" {
  let mut rejected = false
  ignore(
    TypesafeProvider::{ }.login(
      ScriptedPrompt::{ response: "   ", } as &@oauth.AuthPromptInteraction,
    ),
  ) catch {
    @oauth.OAuthError::ParseError(message) => {
      assert_true(message.contains("must not be empty"))
      rejected = true
    }
    _ => fail("expected ParseError")
  }
  assert_true(rejected)
}

///|
async test "typesafe api_key login propagates a cancelled prompt" {
  let mut cancelled = false
  ignore(
    TypesafeProvider::{ }.login(
      CancelledPrompt::{ } as &@oauth.AuthPromptInteraction,
    ),
  ) catch {
    @oauth.OAuthError::Cancelled => cancelled = true
    _ => fail("expected Cancelled")
  }
  assert_true(cancelled)
}

///|
test "typesafe api-key rebuild keeps the slot identity and model" {
  let slot = typesafe_catalog_slot(
    TypesafeConfig("stored", base_url="https://jev.example.ai"),
  )
  let rebuilt = match slot.rebuild_on_api_key {
    Some(rebuild) =>
      rebuild(@oauth.ApiKeyCredential::ApiKeyCredential(secret="rotated"))
    None => fail("decision slot must be rebuildable on api_key")
  }
  assert_eq(rebuilt.id, slot.id)
  assert_eq(rebuilt.model_id, "jev-latest")
  assert_true(rebuilt.is_decision())
}

///|
async test "typesafe decision slot refuses conversation chat" {
  let slot = typesafe_catalog_slot(TypesafeConfig("stored"))
  let scope : @posoco.InvocationScope = {
    session_id: @posoco.SessionId::unchecked("typesafe-test"),
    run_id: @posoco.RunId::unchecked("run-1"),
    effect_id: None,
    pressure: None,
  }
  let mut rejected = false
  ignore(
    slot.port.chat(
      scope,
      [],
      [],
      @posoco.ChatOptions::{ temperature: None, max_output_tokens: None, },
      @posoco.StreamMode::NoStream,
    ),
  ) catch {
    @posoco.ModelError::RequestBuild(message) => {
      assert_true(message.contains("decision-only"))
      rejected = true
    }
    _ => fail("expected RequestBuild")
  }
  assert_true(rejected)
}
