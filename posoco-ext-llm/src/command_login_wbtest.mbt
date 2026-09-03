///|
/// Deterministic OAuth fakes for the router command boundary. These tests do
/// not exercise a provider's network flow; they verify the router's
/// orchestration, persistence, and slot replacement contract.

///|
struct LoginTestOAuth {
  credential : @oauth.Credential
}

///|
pub impl @oauth.OAuthProvider for LoginTestOAuth with fn provider_id(
  _self : LoginTestOAuth,
) -> String {
  "test-oauth"
}

///|
pub impl @oauth.OAuthProvider for LoginTestOAuth with fn login(
  self : LoginTestOAuth,
  interaction : &@oauth.AuthInteraction,
) -> @oauth.Credential raise @oauth.OAuthError {
  interaction.notify(@oauth.AuthMessage::Progress("login-test"))
  self.credential
}

///|
pub impl @oauth.OAuthProvider for LoginTestOAuth with fn refresh(
  self : LoginTestOAuth,
  _credential : @oauth.Credential,
) -> @oauth.Credential raise @oauth.OAuthError {
  self.credential
}

///|
pub impl @oauth.OAuthProvider for LoginTestOAuth with fn to_auth(
  _self : LoginTestOAuth,
  credential : @oauth.Credential,
) -> @oauth.AuthHeader {
  credential.to_auth_header()
}

///|
struct LoginTestStore {
  credentials : Map[String, @oauth.Credential]
}

///|
/// API-key fakes keep the provider-neutral prompt/store contract executable.
struct LoginTestApiKeyProvider {}

///|
/// Provider with the same public provider id as the OAuth fake. This lets
/// the canonical store regression prove that explicit method selection is a
/// one-record replacement rather than two independent records.
struct LoginTestBothApiKeyProvider {}

///|
pub impl ApiKeyFactory for LoginTestApiKeyProvider with fn provider_id(
  _self : LoginTestApiKeyProvider,
) -> String {
  "test-api-key"
}

///|
pub impl ApiKeyFactory for LoginTestBothApiKeyProvider with fn provider_id(
  _self : LoginTestBothApiKeyProvider,
) -> String {
  "test-oauth"
}

///|
pub impl ApiKeyFactory for LoginTestBothApiKeyProvider with fn credential_id(
  _self : LoginTestBothApiKeyProvider,
) -> String {
  "test-oauth"
}

///|
pub impl ApiKeyFactory for LoginTestBothApiKeyProvider with fn login(
  _self : LoginTestBothApiKeyProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="test API key"),
  )
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}

///|
pub impl ApiKeyFactory for LoginTestApiKeyProvider with fn credential_id(
  _self : LoginTestApiKeyProvider,
) -> String {
  "test-api-key"
}

///|
pub impl ApiKeyFactory for LoginTestApiKeyProvider with fn login(
  _self : LoginTestApiKeyProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="test API key"),
  )
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}

///|
struct LoginTestPrompt {
  value : String
}

///|
pub impl @oauth.AuthPromptInteraction for LoginTestPrompt with fn prompt(
  self : LoginTestPrompt,
  _request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  self.value
}

///|
pub impl @oauth.CredentialStore for LoginTestStore with fn read(
  self : LoginTestStore,
  provider_id : String,
) -> @oauth.Credential? raise @oauth.OAuthError {
  self.credentials.get(provider_id)
}

///|
pub impl @oauth.CredentialStore for LoginTestStore with fn write(
  self : LoginTestStore,
  provider_id : String,
  credential : @oauth.Credential,
) -> Unit raise @oauth.OAuthError {
  self.credentials[provider_id] = credential
}

///|
pub impl @oauth.CredentialStore for LoginTestStore with fn delete(
  self : LoginTestStore,
  provider_id : String,
) -> Unit raise @oauth.OAuthError {
  self.credentials.remove(provider_id)
}

///|
fn login_test_credential() -> @oauth.Credential {
  @oauth.Credential::Credential(
    access_token="access-token",
    refresh_token="refresh-token",
    expires_at=0,
  )
}

///|
fn login_test_slot(
  oauth : &@oauth.OAuthProvider,
  rebuild? : ((@oauth.Credential) -> ModelSlot)? = None,
) -> ModelSlot {
  let port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: ["before-login"],
  }
  ModelSlot::ModelSlot(
    id="oauth-slot",
    label="OAuth slot",
    provider_id="test-oauth",
    model_id="test-model",
    port~,
    oauth=Some(oauth),
    rebuild_on_credential=rebuild,
  )
}

///|
async test "login command lists provider auth capabilities" {
  let oauth_impl = LoginTestOAuth::{ credential: login_test_credential(), }
  let oauth : &@oauth.OAuthProvider = oauth_impl
  let router = RouterModelPort(slots=[login_test_slot(oauth)])
  let outcome = router.invoke("login", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ui_hint~) => {
      ignore(feedback)
      ignore(ui_hint)
      match structured {
        Some(Json::Array(values)) =>
          assert_eq(values, [
            Json::object(
              Map::from_array([
                ("provider", Json::string("test-oauth")),
                ("methods", Json::array([Json::string("oauth")])),
              ]),
            ),
          ])
        _ => fail("expected provider auth capability catalog")
      }
    }
    _ => fail("expected OAuth provider listing")
  }
}

///|
async test "login persists credential and rebuilds matching slots" {
  let credential = login_test_credential()
  let oauth_impl = LoginTestOAuth::{ credential, }
  let oauth : &@oauth.OAuthProvider = oauth_impl
  let store_impl = LoginTestStore::{ credentials: Map::from_array([]), }
  let store : &@oauth.CredentialStore = store_impl
  let interaction_impl = @oauth.NoopAuthInteraction::NoopAuthInteraction()
  let interaction : &@oauth.AuthInteraction = interaction_impl
  let rebuild : (@oauth.Credential) -> ModelSlot = fn(credential) {
    let port : &@posoco.ModelPort = RouterTestPort::{
      reasoning_effort_values: [credential.access_token],
    }
    ModelSlot::ModelSlot(
      id="oauth-slot",
      label="OAuth slot (authenticated)",
      provider_id="test-oauth",
      model_id="test-model",
      port~,
      oauth=Some(oauth),
      thinking_efforts=[credential.access_token],
    )
  }
  let router = RouterModelPort(
    slots=[login_test_slot(oauth, rebuild=Some(rebuild))],
    cred_store=Some(store),
    auth_interaction=Some(interaction),
  )
  let outcome = router.invoke(
    "login",
    Json::object(Map::from_array([("provider", Json::string("test-oauth"))])),
  )
  assert_true(outcome is @posoco.CommandOutcome::Success(..))
  match store_impl.credentials.get("test-oauth") {
    Some(saved) => assert_eq(saved.access_token, "access-token")
    None => fail("credential was not persisted")
  }
  assert_eq(router.list_slots()[0].label, "OAuth slot (authenticated)")
  assert_eq(router.list_slots()[0].thinking_efforts, ["access-token"])
}

///|
async test "login rejects OAuth provider without configured dependencies" {
  let oauth_impl = LoginTestOAuth::{ credential: login_test_credential(), }
  let oauth : &@oauth.OAuthProvider = oauth_impl
  // Provide the auth interaction (so the login flow advances past it) but omit
  // the credential store; the store-missing branch is the documented rejection.
  let interaction_impl = @oauth.NoopAuthInteraction::NoopAuthInteraction()
  let interaction : &@oauth.AuthInteraction = interaction_impl
  let router = RouterModelPort(
    slots=[login_test_slot(oauth)],
    auth_interaction=Some(interaction),
  )
  let result = Ok(
    router.invoke(
      "login",
      Json::object(Map::from_array([("provider", Json::string("test-oauth"))])),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.CommandError::ExecutionFailed(message)) =>
      assert_true(message.contains("credential store"))
    _ => fail("expected a missing dependency failure")
  }
}

///|
async test "login persists API key and rebuilds matching slots" {
  let api_impl = LoginTestApiKeyProvider::{ }
  let api : &ApiKeyFactory = api_impl
  let store_impl = @oauth.InMemoryApiKeyStore()
  let store : &@oauth.ApiKeyStore = store_impl
  let prompt_impl = LoginTestPrompt::{ value: "api-secret", }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: ["before-login"],
  }
  let slot = ModelSlot::ModelSlot(
    id="api-key-slot",
    label="API key slot",
    provider_id="test-api-key",
    model_id="test-model",
    port~,
    api_key=Some(api),
    rebuild_on_api_key=Some(fn(credential) {
      let rebuilt_port : &@posoco.ModelPort = RouterTestPort::{
        reasoning_effort_values: [credential.secret],
      }
      ModelSlot::ModelSlot(
        id="api-key-slot",
        label="API key slot (authenticated)",
        provider_id="test-api-key",
        model_id="test-model",
        port=rebuilt_port,
        api_key=Some(api),
        thinking_efforts=[credential.secret],
      )
    }),
  )
  let router = RouterModelPort(
    slots=[slot],
    api_key_store=Some(store),
    auth_prompt=Some(prompt),
  )
  let outcome = router.invoke(
    "login",
    Json::object(
      Map::from_array([
        ("provider", Json::string("test-api-key")),
        ("method", Json::string("api_key")),
      ]),
    ),
  )
  assert_true(outcome is @posoco.CommandOutcome::Success(..))
  match store_impl.credentials.get("test-api-key") {
    Some(saved) => assert_eq(saved.secret, "api-secret")
    None => fail("API key was not persisted")
  }
  assert_eq(router.list_slots()[0].label, "API key slot (authenticated)")
  assert_eq(router.list_slots()[0].thinking_efforts, ["api-secret"])
}

///|
async test "login requires a method when a provider exposes both methods" {
  let oauth_impl = LoginTestOAuth::{ credential: login_test_credential(), }
  let oauth : &@oauth.OAuthProvider = oauth_impl
  let api_impl = LoginTestApiKeyProvider::{ }
  let api : &ApiKeyFactory = api_impl
  let port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  let slot = ModelSlot::ModelSlot(
    id="both-slot",
    label="Both methods",
    provider_id="test-oauth",
    model_id="test-model",
    port~,
    oauth=Some(oauth),
    api_key=Some(api),
  )
  let router = RouterModelPort(slots=[slot])
  let result = Ok(router.invoke("login", Json::string("test-oauth"))) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.CommandError::InvalidArgs(reason~)) =>
      assert_true(reason.contains("requires method"))
    _ => fail("expected ambiguous auth method to be rejected")
  }
}

///|
async test "canonical credential store replaces OAuth with API key atomically" {
  let oauth_impl = LoginTestOAuth::{ credential: login_test_credential(), }
  let oauth : &@oauth.OAuthProvider = oauth_impl
  let api_impl = LoginTestBothApiKeyProvider::{ }
  let api : &ApiKeyFactory = api_impl
  let store_impl = @oauth.InMemoryProviderCredentialStore()
  let store : &@oauth.ProviderCredentialStore = store_impl
  let auth_impl = @oauth.NoopAuthInteraction::NoopAuthInteraction()
  let auth : &@oauth.AuthInteraction = auth_impl
  let prompt_impl = LoginTestPrompt::{ value: "api-secret", }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  let slot = ModelSlot::ModelSlot(
    id="both-canonical-slot",
    label="Both canonical",
    provider_id="test-oauth",
    model_id="test-model",
    port~,
    oauth=Some(oauth),
    api_key=Some(api),
  )
  let router = RouterModelPort(
    slots=[slot],
    provider_credential_store=Some(store),
    auth_interaction=Some(auth),
    auth_prompt=Some(prompt),
  )
  let first = router.invoke(
    "login",
    Json::object(
      Map::from_array([
        ("provider", Json::string("test-oauth")),
        ("method", Json::string("oauth")),
      ]),
    ),
  )
  assert_true(first is @posoco.CommandOutcome::Success(..))
  match store_impl.read("test-oauth") {
    Some(@oauth.ProviderCredential::OAuth(_)) => ()
    _ => fail("canonical store must contain OAuth after OAuth login")
  }
  let second = router.invoke(
    "login",
    Json::object(
      Map::from_array([
        ("provider", Json::string("test-oauth")),
        ("method", Json::string("api_key")),
      ]),
    ),
  )
  assert_true(second is @posoco.CommandOutcome::Success(..))
  match store_impl.read("test-oauth") {
    Some(@oauth.ProviderCredential::ApiKey(value)) =>
      assert_eq(value.secret, "api-secret")
    _ => fail("explicit API-key login must replace OAuth record")
  }
}
