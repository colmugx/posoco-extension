///|
/// Provider-owned configuration source and catalog contribution for OpenCode
/// Zen.
///
/// One `OpenCodeZenProvider` instance owns the Zen gateway contract: the
/// conventional base URL, the `opencode` provider/credential id, and the
/// OpenAI-compatible wire (reused, not reimplemented). The host (cetas-core)
/// constructs this factory once and registers it alongside the other named
/// providers; this adapter never reads the settings map directly and never
/// decides which ids it serves — it owns only the Zen endpoint, the catalog
/// decode, and the API-key login prompt.

///|
pub(all) struct OpenCodeZenProvider {
  ctx : @devkit.ExtContext
}

///|
/// Construct the Zen provider factory. `ctx` carries host-injected services
/// (device id, telemetry) that the wire layer may consult; it is opaque to
/// this adapter and threaded straight into the reused port.
pub fn OpenCodeZenProvider::OpenCodeZenProvider(
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> OpenCodeZenProvider {
  { ctx, }
}

///|
/// Read a string-valued setting for the Zen provider. Empty strings and
/// non-string shapes are typed composition failures, not silent skips, so a
/// malformed `providers.opencode` entry cannot produce a half-configured agent.
fn zen_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_opencode_zen",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_opencode_zen",
        detail="setting must be a string: " + key,
      )
  }
}

///|
/// Resolve the API key from either the credential store or settings, or report
/// that the provider is unconfigured. Shared by `build` and `refresh` so the
/// two paths apply identical credential rules.
fn zen_resolve_api_key(
  source : @llm.ProviderConfigSource,
) -> String? raise @posoco.CompositionError {
  let credential = source.effective_credential(zen_provider_id)
  match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_opencode_zen",
        detail="OAuth credential is not supported for provider " +
          zen_provider_id,
      )
    Some(@oauth.ProviderCredential::ApiKey(credential)) =>
      Some(credential.secret)
    None => zen_setting_string(source, "api_key")
  }
}

///|
/// Resolve the Zen base URL, applying the conventional default when settings
/// omit it. The endpoint prefix is always empty for Zen because the base URL
/// already carries `/v1`.
fn zen_resolve_base_url(
  source : @llm.ProviderConfigSource,
) -> String raise @posoco.CompositionError {
  match zen_setting_string(source, "base_url") {
    Some(value) => value
    None => zen_default_base_url
  }
}

///|
/// Resolve the configured model, defaulting to a stable coding model from the
/// gateway's current catalog. The default is only used on the static `build`
/// path before the live catalog arrives; `refresh` always reads the real list.
fn zen_resolve_model(
  source : @llm.ProviderConfigSource,
) -> String raise @posoco.CompositionError {
  match zen_setting_string(source, "model") {
    Some(value) => value
    None => "claude-sonnet-5"
  }
}

///|
pub impl @llm.ProviderFactory for OpenCodeZenProvider with fn provider_id(
  _self : OpenCodeZenProvider,
) -> String {
  zen_provider_id
}

///|
pub impl @llm.ProviderFactory for OpenCodeZenProvider with fn credential_id(
  _self : OpenCodeZenProvider,
) -> String {
  zen_provider_id
}

///|
/// Static build: no network. Returns a catalog built over the resolved
/// credential, endpoint, and (possibly defaulted) model. Composition must not
/// block on the Zen discovery endpoint: without host-cached records this is a
/// single slot and the full list arrives later via `refresh`; with cached
/// records (a previous refresh's projection) the full list is reconstructed
/// offline, so restarts announce the complete catalog immediately.
pub impl @llm.ProviderFactory for OpenCodeZenProvider with fn build(
  self : OpenCodeZenProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let api_key = match zen_resolve_api_key(source) {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let base_url = zen_resolve_base_url(source)
  let model = zen_resolve_model(source)
  let config = @openai_compatible.OpenAICompatibleConfig(
    api_key,
    base_url~,
    model~,
  )
  let api_key_factory : &@llm.ApiKeyFactory = self
  let catalog = match parse_cached_zen_models(source.cached_models) {
    Some(models) => zen_model_catalog(config, models, model, api_key_factory)
    None => zen_static_catalog(config, api_key_factory)
  }
  @llm.ProviderBuildResult::Ready(catalog)
}

///|
pub impl @llm.RefreshableProviderFactory for OpenCodeZenProvider with fn provider_id(
  _self : OpenCodeZenProvider,
) -> String {
  zen_provider_id
}

///|
/// Live catalog refresh lives in refresh_native_js.mbt (it calls
/// `fetch_zen_models`, which drives `@http` — native+js only). On
/// wasm/wasm-gc a fallback impl in refresh_wasm_fallback.mbt raises a clear
/// `CompositionError` so the trait is fully satisfied on every backend.

///|
/// Provider-owned API-key login. The host supplies a provider-neutral secret
/// prompt; validation and the credential shape stay in this extension.
pub impl @llm.ApiKeyFactory for OpenCodeZenProvider with fn provider_id(
  _self : OpenCodeZenProvider,
) -> String {
  zen_provider_id
}

///|
pub impl @llm.ApiKeyFactory for OpenCodeZenProvider with fn credential_id(
  _self : OpenCodeZenProvider,
) -> String {
  zen_provider_id
}

///|
pub impl @llm.ApiKeyFactory for OpenCodeZenProvider with fn login(
  _self : OpenCodeZenProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="OpenCode Zen API key"),
  )
  if secret.length() == 0 {
    raise @oauth.OAuthError::ParseError(
      "OpenCode Zen API key must not be empty",
    )
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}
