///| 
/// Provider-factory seams for host composition.
///
/// A host supplies an opaque provider settings object and a generic OAuth
/// credential. Provider extensions own interpretation of those values:
/// defaults, endpoint/protocol selection, model capabilities, and credential
/// rebuilding stay behind this contract. The router only receives ready
/// `ProviderModelCatalog` values.

///|
pub(all) struct ProviderConfigSource {
  /// Provider-owned settings copied from a generic host configuration source.
  settings : Json?
  /// Canonical tagged credential. Hosts should use this field for all new
  /// composition; it represents the one active auth method for this provider.
  provider_credential : @oauth.ProviderCredential?
  /// Generic credential-store result. Provider extensions decide whether and
  /// how this credential is used (including canonical OAuth provider ids).
  ///
  /// Deprecated compatibility input. If it is supplied together with
  /// `api_key_credential`, composition fails rather than preferring OAuth.
  credential : @oauth.Credential?
  /// Generic API-key credential loaded by the host store. Providers validate
  /// and interpret the opaque secret; the host never parses it.
  ///
  /// Deprecated compatibility input; see `credential` above.
  api_key_credential : @oauth.ApiKeyCredential?
}

///|
pub fn ProviderConfigSource::ProviderConfigSource(
  settings? : Json? = None,
  provider_credential? : @oauth.ProviderCredential? = None,
  credential? : @oauth.Credential? = None,
  api_key_credential? : @oauth.ApiKeyCredential? = None,
) -> ProviderConfigSource {
  { settings, provider_credential, credential, api_key_credential }
}

///|
/// Resolve the canonical tagged credential for a provider. The legacy fields
/// remain source-compatible for existing hosts, but a host that exposes both
/// records is an observable composition failure: silently choosing OAuth would
/// make an explicit API-key login disappear after recomposition.
pub fn ProviderConfigSource::effective_credential(
  self : ProviderConfigSource,
  provider_id : String,
) -> @oauth.ProviderCredential? raise @posoco.CompositionError {
  match self.provider_credential {
    Some(value) => {
      if self.credential is Some(_) || self.api_key_credential is Some(_) {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_llm.credentials",
          detail="ambiguous credential for provider " + provider_id,
        )
      }
      Some(value)
    }
    None =>
      match (self.credential, self.api_key_credential) {
        (Some(_), Some(_)) =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_llm.credentials",
            detail="ambiguous credential for provider " + provider_id,
          )
        (Some(value), None) => Some(@oauth.ProviderCredential::OAuth(value))
        (None, Some(value)) => Some(@oauth.ProviderCredential::ApiKey(value))
        (None, None) => None
      }
  }
}

///|
/// Return one opaque setting without imposing provider-specific names on the
/// host. A missing/non-object source simply has no setting; factories decide
/// which keys are required and raise a typed composition error for malformed
/// values.
pub fn ProviderConfigSource::setting(
  self : ProviderConfigSource,
  key : String,
) -> Json? raise @posoco.CompositionError {
  match self.settings {
    Some(Json::Object(fields)) => fields.get(key)
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_llm.provider_source",
        detail="provider settings must be a JSON object",
      )
    None => None
  }
}

///|
pub fn ProviderConfigSource::has_settings(self : ProviderConfigSource) -> Bool {
  match self.settings {
    Some(_) => true
    None => false
  }
}

///|
/// Result of asking a provider extension to resolve a catalog. Missing
/// credentials/settings are a normal unconfigured state; malformed configured
/// values remain composition failures and must not be silently skipped.
pub(all) enum ProviderBuildResult {
  Ready(ProviderModelCatalog)
  Unconfigured
}

///|
/// Public extension seam for provider-owned configuration and catalog
/// construction. Implementations never expose endpoint or protocol details to
/// the host/router.
pub(open) trait ProviderFactory {
  fn provider_id(Self) -> String
  /// Canonical key used by the generic credential store. It may differ from
  /// the user-facing provider id (for example OpenAI/Codex OAuth).
  fn credential_id(Self) -> String
  fn build(Self, source : ProviderConfigSource) -> ProviderBuildResult raise @posoco.CompositionError
}

///|
/// Optional provider-owned model discovery seam.
///
/// A provider implements this trait only when its authenticated endpoint can
/// return a live model catalog. Hosts must call `refresh` explicitly (for
/// example during first startup or immediately after a successful login); a
/// normal `ProviderFactory::build` remains a pure snapshot reconstruction and
/// never performs an implicit network request.  Transport and schema failures
/// are raised as `CompositionError` by the provider implementation, so a host
/// cannot accidentally fall back to a stale or static catalog.
pub(open) trait RefreshableProviderFactory {
  fn provider_id(Self) -> String
  async fn refresh(Self, source : ProviderConfigSource) -> ProviderBuildResult raise @posoco.CompositionError
}

///|
/// Optional OAuth contribution paired with a ProviderFactory. Keeping login
/// as a separate trait means non-OAuth providers do not implement fake login
/// paths or know about host interaction details.
pub(open) trait OAuthFactory {
  fn provider_id(Self) -> String
  fn credential_id(Self) -> String
  async fn login(Self, interaction : &@oauth.AuthInteraction) -> @oauth.Credential raise @oauth.OAuthError
}

///|
/// Provider-neutral authentication method advertised by a model catalog.
pub(all) enum AuthMethod {
  ApiKey
  OAuth
} derive(Eq, Debug)

///|
pub fn AuthMethod::to_id(self : AuthMethod) -> String {
  match self {
    ApiKey => "api_key"
    OAuth => "oauth"
  }
}

///|
/// Provider-owned API-key login contribution. The provider prompts and
/// validates its secret; the router only persists it and rebuilds slots.
pub(open) trait ApiKeyFactory {
  fn provider_id(Self) -> String
  fn credential_id(Self) -> String
  async fn login(Self, interaction : &@oauth.AuthPromptInteraction) -> @oauth.ApiKeyCredential raise @oauth.OAuthError
}
