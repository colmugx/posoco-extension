///|
/// Provider-owned configuration source and catalog contribution for OpenCode
/// Go: the endpoint, the catalog decode, both login methods (Console account
/// grant and API key), and the `/usage` quota source. The wire machinery and
/// identity conventions come from `posoco-ext-opencode-zen`; this factory is
/// the Go plane's product seam.

///|
pub(all) struct OpenCodeGoProvider {
  ctx : @devkit.ExtContext
}

///|
pub fn OpenCodeGoProvider::OpenCodeGoProvider(
  ctx~ : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> OpenCodeGoProvider {
  { ctx, }
}

///|
/// Read a string-valued setting for the Go provider. Empty strings and
/// non-string shapes are typed composition failures, so a malformed
/// `providers.opencode-go` entry cannot produce a half-configured agent.
fn go_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_opencode_go",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_opencode_go",
        detail="setting must be a string: " + key,
      )
  }
}

///|
/// Resolved auth: API-key secret or grant token, plus the grant's workspace
/// routing.
priv struct GoAuth {
  api_key : String
  oauth : Bool
  org_id : String?
  api_base : String?
}

///|
/// Resolve the tagged credential, else the `api_key` setting; a grant without
/// an access token is a composition error.
fn go_resolve_auth(
  source : @llm.ProviderConfigSource,
) -> GoAuth? raise @posoco.CompositionError {
  match source.effective_credential(go_provider_id) {
    Some(@oauth.ProviderCredential::OAuth(credential)) =>
      match go_oauth_session(credential) {
        Some(session) =>
          Some({
            api_key: session.access_token,
            oauth: true,
            org_id: session.org_id,
            api_base: session.api_base,
          })
        None =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_opencode_go",
            detail="OpenCode Go OAuth credential is missing its access token; run /login opencode-go",
          )
      }
    Some(@oauth.ProviderCredential::ApiKey(credential)) =>
      Some({
        api_key: credential.secret,
        oauth: false,
        org_id: None,
        api_base: None,
      })
    None =>
      match go_setting_string(source, "api_key") {
        Some(value) =>
          Some({ api_key: value, oauth: false, org_id: None, api_base: None, })
        None => None
      }
  }
}

///|
/// `base_url` setting, then a grant's workspace base, then the default.
fn go_resolve_base_url(
  source : @llm.ProviderConfigSource,
  auth : GoAuth,
) -> String raise @posoco.CompositionError {
  match go_setting_string(source, "base_url") {
    Some(value) => value
    None =>
      match auth.api_base {
        Some(value) => value
        None => go_default_base_url
      }
  }
}

///|
/// Resolve the configured model, defaulting to the vendor's cheap
/// high-allowance coding slot until the live catalog arrives.
fn go_resolve_model(
  source : @llm.ProviderConfigSource,
) -> String raise @posoco.CompositionError {
  match go_setting_string(source, "model") {
    Some(value) => value
    None => go_default_model
  }
}

///|
/// Resolve the subscription plan (informative allowance lookups); the
/// vendor publishes no way to probe the tier, so this stays a setting.
fn go_resolve_plan(
  source : @llm.ProviderConfigSource,
) -> GoPlan raise @posoco.CompositionError {
  match go_setting_string(source, "plan") {
    Some(value) => go_plan_of_setting(value)
    None => Go
  }
}

///|
/// Resolve the per-model wire overrides (same contract as the zen plane).
fn go_protocol_overrides(
  source : @llm.ProviderConfigSource,
) -> Map[String, String] raise @posoco.CompositionError {
  let overrides : Map[String, String] = Map::from_array([])
  match source.setting("protocol_overrides") {
    None => ()
    Some(Json::Object(fields)) =>
      for id, value in fields {
        match value {
          Json::String(wire) =>
            match @zen.wire_kind_of_id(wire) {
              Some(_) => overrides[id] = wire
              None =>
                raise @posoco.CompositionError::ManifestSchemaError(
                  manifest_id="posoco_ext_opencode_go",
                  detail="protocol_overrides names an unknown wire for \{id}: \{wire}",
                )
            }
          _ =>
            raise @posoco.CompositionError::ManifestSchemaError(
              manifest_id="posoco_ext_opencode_go",
              detail="protocol_overrides values must be strings: \{id}",
            )
        }
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_opencode_go",
        detail="setting protocol_overrides must be an object",
      )
  }
  overrides
}

///|
/// Resolve the DeepSeek serving contract from the provider settings. Parsed
/// on every composition, so a malformed key is a typed failure even when no
/// `deepseek*` model is selected.
fn go_deepseek_policy(
  source : @llm.ProviderConfigSource,
) -> @ds.DeepSeekPolicy raise @posoco.CompositionError {
  @ds.DeepSeekPolicy::from_settings(
    source.settings,
    manifest_id="posoco_ext_opencode_go",
  )
}

///|
/// Register the pull-style `/usage` reading under the provider id so the
/// `/status` command and the model picker read the three windows live at
/// command time. Every configured build/refresh re-registers, so the
/// registry holds the latest credential snapshot.
fn go_register_quota_source(
  base_url : String,
  api_key : String,
  extra_headers~ : Map[String, String] = Map::from_array([]),
) -> Unit {
  let source : &@devkit.QuotaSource = GoUsageQuotaSource(
    base_url~,
    api_key~,
    extra_headers~,
  )
  @devkit.quota_registry_register(go_provider_id, source)
}

///|
pub impl @llm.ProviderFactory for OpenCodeGoProvider with fn provider_id(
  _self : OpenCodeGoProvider,
) -> String {
  go_provider_id
}

///|
pub impl @llm.ProviderFactory for OpenCodeGoProvider with fn credential_id(
  _self : OpenCodeGoProvider,
) -> String {
  go_provider_id
}

///|
/// Static build: no network. One slot over the resolved credential and
/// model (or the offline expansion of the host cache), with the wire
/// re-derived from the Go-plane table.
pub impl @llm.ProviderFactory for OpenCodeGoProvider with fn build(
  self : OpenCodeGoProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let auth = match go_resolve_auth(source) {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let base_url = go_resolve_base_url(source, auth)
  let model = go_resolve_model(source)
  let _plan = go_resolve_plan(source)
  let overrides = go_protocol_overrides(source)
  let policy = go_deepseek_policy(source)
  let extra_headers = go_extra_headers(auth.org_id)
  let config = @zen.OpenCodeZenConfig(
    auth.api_key,
    base_url~,
    model~,
    client_id="opencode-go",
    spend_source="posoco_ext_opencode_go",
    extra_headers~,
    bearer_auth=auth.oauth,
  )
  let api_key_factory : &@llm.ApiKeyFactory = self
  let catalog = match @zen.parse_opencode_cached_models(source.cached_models) {
    Some(models) =>
      go_model_catalog(
        config,
        models,
        model,
        Map::from_array([]),
        api_key_factory,
        overrides~,
        policy=Some(policy),
        ctx=self.ctx,
      )
    None =>
      go_static_catalog(
        config,
        api_key_factory,
        overrides~,
        policy=Some(policy),
        ctx=self.ctx,
      )
  }
  go_register_quota_source(base_url, auth.api_key, extra_headers~)
  @llm.ProviderBuildResult::Ready(catalog)
}

///|
pub extend OpenCodeGoProvider with @posoco/ext-llm.ProviderFactory::{
  credential_id,
  provider_id,
  build,
}

///|
/// Provider-owned API-key login. The host supplies the provider-neutral
/// secret prompt; validation stays in this extension.
pub impl @llm.ApiKeyFactory for OpenCodeGoProvider with fn provider_id(
  _self : OpenCodeGoProvider,
) -> String {
  go_provider_id
}

///|
pub impl @llm.ApiKeyFactory for OpenCodeGoProvider with fn credential_id(
  _self : OpenCodeGoProvider,
) -> String {
  go_provider_id
}

///|
pub impl @llm.ApiKeyFactory for OpenCodeGoProvider with fn login(
  _self : OpenCodeGoProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="OpenCode Go API key"),
  )
  if secret.length() == 0 {
    raise @oauth.OAuthError::ParseError("OpenCode Go API key must not be empty")
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}

///|
pub extend OpenCodeGoProvider with @posoco/ext-llm.ApiKeyFactory::{login}

///|
/// Console account login (RFC 8628 device grant).
pub impl @llm.OAuthFactory for OpenCodeGoProvider with fn provider_id(
  _self : OpenCodeGoProvider,
) -> String {
  go_provider_id
}

///|
pub impl @llm.OAuthFactory for OpenCodeGoProvider with fn credential_id(
  _self : OpenCodeGoProvider,
) -> String {
  go_provider_id
}

///|
pub impl @llm.OAuthFactory for OpenCodeGoProvider with fn login(
  _self : OpenCodeGoProvider,
  interaction : &@oauth.AuthInteraction,
) -> @oauth.Credential raise @oauth.OAuthError {
  go_oauth_login(interaction)
}

///|
pub impl @llm.RefreshableProviderFactory for OpenCodeGoProvider with fn provider_id(
  _self : OpenCodeGoProvider,
) -> String {
  go_provider_id
}
