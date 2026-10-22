///|
/// Provider-owned configuration source and catalog contribution for OpenCode
/// Go: the endpoint, the catalog decode, the API-key login prompt, and the
/// `/usage` quota source. The wire machinery and identity conventions come
/// from `posoco-ext-opencode-zen`; this factory is the Go plane's product
/// seam.

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
/// Resolve the API key from the credential store or settings; an OAuth
/// credential is a typed failure — this plane is API-key only.
fn go_resolve_api_key(
  source : @llm.ProviderConfigSource,
) -> String? raise @posoco.CompositionError {
  let credential = source.effective_credential(go_provider_id)
  match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_opencode_go",
        detail="OAuth credential is not supported for provider " +
          go_provider_id,
      )
    Some(@oauth.ProviderCredential::ApiKey(credential)) =>
      Some(credential.secret)
    None => go_setting_string(source, "api_key")
  }
}

///|
/// Resolve the Go base URL, applying the conventional default when settings
/// omit it.
fn go_resolve_base_url(
  source : @llm.ProviderConfigSource,
) -> String raise @posoco.CompositionError {
  match go_setting_string(source, "base_url") {
    Some(value) => value
    None => go_default_base_url
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
fn go_register_quota_source(base_url : String, api_key : String) -> Unit {
  let source : &@devkit.QuotaSource = GoUsageQuotaSource(base_url~, api_key~)
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
  let api_key = match go_resolve_api_key(source) {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let base_url = go_resolve_base_url(source)
  let model = go_resolve_model(source)
  let _plan = go_resolve_plan(source)
  let overrides = go_protocol_overrides(source)
  let policy = go_deepseek_policy(source)
  let config = @zen.OpenCodeZenConfig(
    api_key,
    base_url~,
    model~,
    client_id="opencode-go",
    spend_source="posoco_ext_opencode_go",
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
  go_register_quota_source(base_url, api_key)
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
pub impl @llm.RefreshableProviderFactory for OpenCodeGoProvider with fn provider_id(
  _self : OpenCodeGoProvider,
) -> String {
  go_provider_id
}
