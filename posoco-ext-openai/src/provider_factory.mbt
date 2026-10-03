///| 
/// Provider-owned configuration and OAuth contribution for OpenAI/Codex.

///|
pub(all) struct OpenAIProvider {
  models_transport : &OpenAIModelsHttpTransport?
  /// Injectable OAuth HTTP transport for the load-time token renewal; tests
  /// observe refresh-grant wire requests, production leaves `None` for the
  /// default transport.
  oauth_transport : &@oauth.OAuthHttpTransport?
  cache_dir : String?
  priv last_client_version : Ref[String?]
}

///|
pub fn OpenAIProvider::OpenAIProvider(
  transport? : &OpenAIModelsHttpTransport? = None,
  oauth_transport? : &@oauth.OAuthHttpTransport? = None,
  cache_dir? : String? = None,
) -> OpenAIProvider {
  OpenAIProvider::{
    models_transport: transport,
    oauth_transport,
    cache_dir,
    last_client_version: Ref(None),
  }
}

///|
fn openai_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openai",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openai",
        detail="setting must be a string: " + key,
      )
  }
}

///|
fn openai_default_model() -> String {
  // The default is provider-owned; the host never needs to know OpenAI's
  // model naming or choose a fallback when settings omit `model`.
  "gpt-4o"
}

///|
/// Publish the external intelligence-metrics source under the provider id so
/// the /model pick flow reads it live at command time. The radar feed is
/// credential-free, so every configured build/refresh re-registers the same
/// source (last write wins).
fn openai_register_intelligence_metrics() -> Unit {
  let borrowed : &@devkit.ModelMetricsSource = intelligence_metrics_source()
  @devkit.metrics_registry_register("openai", borrowed)
}

///|
pub impl @llm.ProviderFactory for OpenAIProvider with fn provider_id(
  _self : OpenAIProvider,
) -> String {
  "openai"
}

///|
pub extend OpenAIProvider with @posoco/ext-llm.ProviderFactory::{
  credential_id,
  provider_id,
  build,
}

///|
/// Codex OAuth stores under the OAuth implementation's canonical id, not the
/// user-facing router alias `openai`.
pub impl @llm.ProviderFactory for OpenAIProvider with fn credential_id(
  _self : OpenAIProvider,
) -> String {
  "openai-codex"
}

///|
/// Publish the live usage probe under the provider id so the `/status`
/// command and the router's bar refresh read it live at command time. Every
/// configured build/refresh re-registers, so the registry holds the latest
/// credential snapshot. The usage endpoint is OAuth-only (bearer + account
/// header), so API-key builds leave the id unregistered.
fn openai_register_quota_source(
  transport : &OpenAIModelsHttpTransport?,
  config : OpenAIConfig,
) -> Unit {
  match config.account_id {
    Some(account_id) if account_id.length() > 0 => {
      let source = CodexUsageQuotaSource::CodexUsageQuotaSource(
        transport~,
        access_token=config.api_key,
        account_id~,
      )
      let borrowed : &@devkit.QuotaSource = source
      @devkit.quota_registry_register("openai", borrowed)
    }
    _ => ()
  }
}

///|
pub impl @llm.ProviderFactory for OpenAIProvider with fn build(
  self : OpenAIProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let model = match openai_setting_string(source, "model") {
    Some(value) => value
    None => openai_default_model()
  }
  let credential = source.effective_credential("openai")
  let config = match credential {
    Some(@oauth.ProviderCredential::OAuth(credential)) =>
      OpenAIConfig::from_codex_credential(credential, model)
    Some(@oauth.ProviderCredential::ApiKey(credential)) =>
      match openai_setting_string(source, "base_url") {
        Some(base_url) =>
          OpenAIConfig::with_base_url(credential.secret, model, base_url)
        None => OpenAIConfig(credential.secret, model)
      }
    None => {
      let api_key = match openai_setting_string(source, "api_key") {
        Some(value) => value
        None => return @llm.ProviderBuildResult::Unconfigured
      }
      match openai_setting_string(source, "base_url") {
        Some(base_url) => OpenAIConfig::with_base_url(api_key, model, base_url)
        None => OpenAIConfig(api_key, model)
      }
    }
  }
  let port = OpenAIModelPort(
    config,
    quota_tracker=Some(codex_shared_quota_tracker()),
  )
  // Pull-style quota: the OAuth credential is the only shape that can serve
  // the usage endpoint, so only that build publishes the live source.
  match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      openai_register_quota_source(self.models_transport, config)
    _ => ()
  }
  openai_register_intelligence_metrics()
  // Offline expansion: host-cached discovery records rebuild the full
  // multi-slot catalog without a network request, so a persisted selection
  // restores after restart. A malformed/empty cache degrades to the static
  // single-model catalog and never fails composition.
  let chatgpt_mode = match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) => true
    _ => false
  }
  match parse_cached_openai_models(source.cached_models) {
    Some(models) =>
      @llm.ProviderBuildResult::Ready(
        port.model_catalog_from_cached_models(models, chatgpt_mode~),
      )
    None => @llm.ProviderBuildResult::Ready(port.model_catalog())
  }
}

///|
/// Explicit live model discovery.  `build` remains a static reconstruction;
/// hosts opt into network refresh only through this trait.
pub impl @llm.RefreshableProviderFactory for OpenAIProvider with fn provider_id(
  _self : OpenAIProvider,
) -> String {
  "openai"
}

///|
pub impl @llm.RefreshableProviderFactory for OpenAIProvider with fn refresh(
  self : OpenAIProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let model = match openai_setting_string(source, "model") {
    Some(value) => value
    None => openai_default_model()
  }
  let requested_effort = openai_setting_string(source, "reasoning_effort")
  let credential = source.effective_credential("openai")
  match credential {
    Some(@oauth.ProviderCredential::OAuth(credential)) => {
      let transport_impl = match self.models_transport {
        Some(value) => value
        None => {
          let default_transport = DefaultOpenAIModelsHttpTransport::DefaultOpenAIModelsHttpTransport()
          let transport : &OpenAIModelsHttpTransport = default_transport
          transport
        }
      }
      let cache = OpenAIVersionFileCache::{
        directory: match self.cache_dir {
          Some(directory) => Some(directory)
          None => openai_default_cache_dir()
        },
        last_version: self.last_client_version,
      }
      let client_version = resolve_codex_client_version_with_transport(
        transport_impl,
        Some(cache as &CodexClientVersionCache),
      )
      // Load-time renewal: expired tokens renew up front, a 401 renews once
      // and retries, and only a rejected refresh_token surfaces here. The
      // successful credential flows into the rebuilt slots so the composed
      // router serves fresh tokens, not the stale stored one.
      let (models, active_credential) = refresh_codex_models_with_renewal(
        transport_impl,
        self.oauth_transport,
        credential,
        source.credential_store,
        client_version,
      )
      let config = OpenAIConfig::from_codex_credential(active_credential, model)
      let config = openai_apply_effort(config, requested_effort)
      let account_id = match config.account_id {
        Some(value) if value.length() > 0 => value
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_openai",
            detail="Codex model refresh requires account_id credential metadata",
          )
      }
      // Best-effort usage probe: refresh is already a network round trip,
      // so the 5h/weekly snapshot starts populated without waiting for the
      // first chat response. Failure is silent — the header capture on chat
      // responses remains the authoritative feed.
      let usage : Result[Array[@devkit.QuotaReading], String] = fetch_codex_usage_with_transport(
        transport_impl,
        codex_oauth_api_base(),
        config.api_key,
        account_id,
      ) catch {
        err => Err("Codex usage refresh failed: " + err.to_string())
      }
      match usage {
        Ok(readings) => codex_shared_quota_tracker().capture_readings(readings)
        Err(_) => ()
      }
      let port = OpenAIModelPort(
        config,
        quota_tracker=Some(codex_shared_quota_tracker()),
      )
      // Same registry publication as build: refresh carries the renewed
      // credential, so the /status pull source follows it.
      openai_register_quota_source(Some(transport_impl), config)
      openai_register_intelligence_metrics()
      @llm.ProviderBuildResult::Ready(
        port.model_catalog_from_codex_models(models),
      )
    }
    Some(@oauth.ProviderCredential::ApiKey(credential)) => {
      let base_url = match openai_setting_string(source, "base_url") {
        Some(value) => value
        None => openai_api_base_url()
      }
      let config = OpenAIConfig::with_base_url(
        credential.secret,
        model,
        base_url,
      )
      let config = openai_apply_effort(config, requested_effort)
      let transport_impl = match self.models_transport {
        Some(value) => value
        None => {
          let default_transport = DefaultOpenAIModelsHttpTransport::DefaultOpenAIModelsHttpTransport()
          let transport : &OpenAIModelsHttpTransport = default_transport
          transport
        }
      }
      let models = fetch_openai_models_with_transport(
        transport_impl,
        config.base_url,
        config.api_key,
      ) catch {
        err =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_openai",
            detail="OpenAI API model catalog refresh failed: " + err.to_string(),
          )
      }
      let port = OpenAIModelPort(
        config,
        quota_tracker=Some(codex_shared_quota_tracker()),
      )
      openai_register_intelligence_metrics()
      @llm.ProviderBuildResult::Ready(
        port.model_catalog_from_api_models(models),
      )
    }
    None => {
      let api_key = match openai_setting_string(source, "api_key") {
        Some(value) => value
        None => return @llm.ProviderBuildResult::Unconfigured
      }
      let base_url = match openai_setting_string(source, "base_url") {
        Some(value) => value
        None => openai_api_base_url()
      }
      let config = OpenAIConfig::with_base_url(api_key, model, base_url)
      let config = openai_apply_effort(config, requested_effort)
      let transport_impl = match self.models_transport {
        Some(value) => value
        None => {
          let default_transport = DefaultOpenAIModelsHttpTransport::DefaultOpenAIModelsHttpTransport()
          let transport : &OpenAIModelsHttpTransport = default_transport
          transport
        }
      }
      let models = fetch_openai_models_with_transport(
        transport_impl,
        config.base_url,
        config.api_key,
      ) catch {
        err =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_openai",
            detail="OpenAI API model catalog refresh failed: " + err.to_string(),
          )
      }
      let port = OpenAIModelPort(
        config,
        quota_tracker=Some(codex_shared_quota_tracker()),
      )
      openai_register_intelligence_metrics()
      @llm.ProviderBuildResult::Ready(
        port.model_catalog_from_api_models(models),
      )
    }
  }
}

///|
pub impl @llm.OAuthFactory for OpenAIProvider with fn provider_id(
  _self : OpenAIProvider,
) -> String {
  "openai"
}

///|
pub extend OpenAIProvider with @posoco/ext-llm.OAuthFactory::{login}

///|
pub impl @llm.OAuthFactory for OpenAIProvider with fn credential_id(
  _self : OpenAIProvider,
) -> String {
  "openai-codex"
}

///|
pub impl @llm.OAuthFactory for OpenAIProvider with fn login(
  _self : OpenAIProvider,
  interaction : &@oauth.AuthInteraction,
) -> @oauth.Credential raise @oauth.OAuthError {
  let oauth = CodexOAuth::CodexOAuth()
  oauth.login(interaction)
}

///|
/// Provider-owned OpenAI API-key login. The host only renders a generic
/// secret prompt; validation and credential persistence remain on the public
/// provider-extension seam.
pub impl @llm.ApiKeyFactory for OpenAIProvider with fn provider_id(
  _self : OpenAIProvider,
) -> String {
  "openai"
}

///|
pub impl @llm.ApiKeyFactory for OpenAIProvider with fn credential_id(
  _self : OpenAIProvider,
) -> String {
  "openai"
}

///|
pub impl @llm.ApiKeyFactory for OpenAIProvider with fn login(
  _self : OpenAIProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="OpenAI API key"),
  )
  if secret.length() == 0 {
    raise @oauth.OAuthError::ParseError("OpenAI API key must not be empty")
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}
