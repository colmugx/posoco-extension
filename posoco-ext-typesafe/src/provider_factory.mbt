///|
/// Provider-factory contribution for cetas hosts: provider id "typesafe",
/// api_key login, and a decision-only model catalog (slot kind `decision`).

///|
pub(all) struct TypesafeProvider {}

///|
pub fn TypesafeProvider::TypesafeProvider() -> TypesafeProvider {
  TypesafeProvider::{ }
}

///|
fn typesafe_setting_string(
  source : @provider.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.trim().length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_typesafe",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_typesafe",
        detail="setting must be a string: " + key,
      )
  }
}

///|
fn typesafe_setting_timeout(
  source : @provider.ProviderConfigSource,
) -> Int32 raise @posoco.CompositionError {
  match source.setting("timeout_ms") {
    None => 30000
    Some(Json::Number(value, ..)) =>
      if value > 0.0 && value <= 2147483647.0 {
        value.to_int()
      } else {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_typesafe",
          detail="timeout_ms must be a positive integer",
        )
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_typesafe",
        detail="timeout_ms must be a number",
      )
  }
}

///|
/// Resolve the provider config from settings plus the canonical tagged
/// credential. The stored API-key record wins over the settings
/// `api_key` fallback; an OAuth record is a composition failure because
/// TypeSafe only ever issues API keys. `None` = unconfigured.
fn typesafe_provider_config(
  source : @provider.ProviderConfigSource,
) -> TypesafeConfig? raise @posoco.CompositionError {
  let model = match typesafe_setting_string(source, "model") {
    Some(value) => value
    None => "jev-latest"
  }
  let base_url = match typesafe_setting_string(source, "base_url") {
    Some(value) => value
    None => "https://api.typesafe.ai"
  }
  let timeout_ms = typesafe_setting_timeout(source)
  let fallback = match typesafe_setting_string(source, "api_key") {
    Some(value) => value
    None => ""
  }
  let api_key = match source.effective_credential(typesafe_credential_id()) {
    Some(@oauth.ProviderCredential::ApiKey(credential)) => {
      if credential.secret.trim().length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_typesafe",
          detail="stored API-key credential is empty",
        )
      }
      credential.secret
    }
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_typesafe",
        detail="credential '" +
          typesafe_credential_id() +
          "' must be an API key",
      )
    None => fallback
  }
  if api_key.trim().length() == 0 {
    return None
  }
  Some(TypesafeConfig(api_key, model~, base_url~, timeout_ms~))
}

///|
/// Build the provider's one decision slot. The DecisionPort shares the
/// host's credential store so a stored `typesafe` record stays authoritative
/// over the config fallback at request time.
fn typesafe_catalog_slot(
  config : TypesafeConfig,
  credential_store~ : &@oauth.ProviderCredentialStore? = None,
) -> @provider.ModelSlot {
  let api_key : &@provider.ApiKeyFactory = TypesafeProvider::{ }
  let chat_port : &@posoco.ModelPort = TypesafeDecisionSlotPort::{ }
  let decision : &@posoco.DecisionPort = TypesafeDecisionPort(
    config,
    credential_store~,
    credential_id=typesafe_credential_id(),
  )
  @provider.ModelSlot::ModelSlot(
    id="typesafe/" + config.model,
    label="TypeSafe / " + config.model,
    provider_id="typesafe",
    model_id=config.model,
    port=chat_port,
    kind=@provider.ModelKind::Decision,
    decision_port=Some(decision),
    api_key=Some(api_key),
    capabilities=["decision"],
    rebuild_on_api_key=Some(fn(credential) {
      typesafe_catalog_slot(
        TypesafeConfig(
          credential.secret,
          model=config.model,
          base_url=config.base_url,
          timeout_ms=config.timeout_ms,
        ),
        credential_store~,
      )
    }),
  )
}

///|
pub impl @provider.ProviderFactory for TypesafeProvider with fn provider_id(
  _self : TypesafeProvider,
) -> String {
  "typesafe"
}

///|
pub extend TypesafeProvider with @provider.ProviderFactory::{
  credential_id,
  provider_id,
  build,
}

///|
pub impl @provider.ProviderFactory for TypesafeProvider with fn credential_id(
  _self : TypesafeProvider,
) -> String {
  typesafe_credential_id()
}

///|
pub impl @provider.ProviderFactory for TypesafeProvider with fn build(
  _self : TypesafeProvider,
  source : @provider.ProviderConfigSource,
) -> @provider.ProviderBuildResult raise @posoco.CompositionError {
  let config = match typesafe_provider_config(source) {
    Some(config) => config
    None => return @provider.ProviderBuildResult::Unconfigured
  }
  @provider.ProviderBuildResult::Ready(
    @provider.ProviderModelCatalog::ProviderModelCatalog(
      provider_id="typesafe",
      slots=[
        typesafe_catalog_slot(config, credential_store=source.credential_store),
      ],
      capabilities=["decision", "api_key"],
    ),
  )
}

///|
pub impl @provider.ApiKeyFactory for TypesafeProvider with fn provider_id(
  _self : TypesafeProvider,
) -> String {
  "typesafe"
}

///|
pub extend TypesafeProvider with @provider.ApiKeyFactory::{login}

///|
pub impl @provider.ApiKeyFactory for TypesafeProvider with fn credential_id(
  _self : TypesafeProvider,
) -> String {
  typesafe_credential_id()
}

///|
/// Provider-owned api_key login. A cancelled prompt, a UI failure, or an
/// empty secret raises so `/login typesafe` fails explicitly; the settings
/// `api_key` fallback is never silently reused as the login result.
pub impl @provider.ApiKeyFactory for TypesafeProvider with fn login(
  _self : TypesafeProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="TypeSafe API key"),
  )
  if secret.trim().length() == 0 {
    raise @oauth.OAuthError::ParseError("TypeSafe API key must not be empty")
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}

///|
/// Slot composition requires a ModelPort even for a decision-only provider.
/// TypeSafe serves semantic judgement only: both chat methods fail loudly
/// instead of silently serving conversation traffic.
priv struct TypesafeDecisionSlotPort {}

///|
impl @posoco.ModelPort for TypesafeDecisionSlotPort with fn chat(
  _self : TypesafeDecisionSlotPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::RequestBuild(
    "TypeSafe Jev is decision-only; conversation chat is not available",
  )
}

///|
impl @posoco.ModelPort for TypesafeDecisionSlotPort with fn compact(
  _self : TypesafeDecisionSlotPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "TypeSafe Jev is decision-only; compact is not available",
  )
}

///|
impl @posoco.ModelPort for TypesafeDecisionSlotPort with fn provider_config(
  _self : TypesafeDecisionSlotPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}
