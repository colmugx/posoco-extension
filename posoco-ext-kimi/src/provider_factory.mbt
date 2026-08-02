///| 
/// Provider-owned configuration and OAuth contribution for Kimi.

///|
pub(all) struct KimiProvider {
  ctx : @devkit.ExtContext
}

///|
pub fn KimiProvider::new(
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> KimiProvider {
  { ctx, }
}

///|
fn kimi_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_kimi",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_kimi",
        detail="setting must be a string: " + key,
      )
  }
}

///|
fn kimi_endpoint_parts(url : String) -> (String, String) {
  match url.find("://") {
    None => (url, "")
    Some(protocol_end) => {
      let after_start = protocol_end + 3
      let after = url.sub(start=after_start)
      match after.find("/") {
        None => (url, "")
        Some(slash) => {
          let host_end = after_start + slash
          let clean = url.sub(end=host_end).to_owned()
          let prefix = after.sub(start=slash).to_owned()
          match prefix.strip_suffix("/") {
            Some(value) => (clean, value.to_owned())
            None => (clean, prefix)
          }
        }
      }
    }
  }
}

///|
fn kimi_default_model() -> String {
  KimiConfig::new("").model
}

///|
fn kimi_model(
  source : @llm.ProviderConfigSource,
) -> String raise @posoco.CompositionError {
  match kimi_setting_string(source, "model") {
    Some(value) => value
    None => kimi_default_model()
  }
}

///|
fn kimi_effort(
  source : @llm.ProviderConfigSource,
) -> String raise @posoco.CompositionError {
  match kimi_setting_string(source, "reasoning_effort") {
    Some(value) => value
    None => "high"
  }
}

///|
pub impl @llm.ProviderFactory for KimiProvider with fn provider_id(
  _self : KimiProvider,
) -> String {
  "kimi"
}

///|
pub impl @llm.ProviderFactory for KimiProvider with fn credential_id(
  _self : KimiProvider,
) -> String {
  "kimi"
}

///|
pub impl @llm.ProviderFactory for KimiProvider with fn build(
  self : KimiProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let model = kimi_model(source)
  let effort = kimi_effort(source)
  let credential = source.effective_credential("kimi")
  let config = match credential {
    Some(@oauth.ProviderCredential::OAuth(credential)) =>
      KimiConfig::from_oauth_credential(
        credential,
        model,
        reasoning_effort=effort,
      )
    Some(@oauth.ProviderCredential::ApiKey(credential)) => {
      let base_setting = match kimi_setting_string(source, "base_url") {
        Some(value) => value
        None => "https://api.moonshot.ai/v1"
      }
      let (base_url, endpoint_prefix) = kimi_endpoint_parts(base_setting)
      KimiConfig::new(
        credential.secret,
        model~,
        base_url~,
        endpoint_prefix~,
        reasoning_effort=effort,
      )
    }
    None => {
      let api_key = match kimi_setting_string(source, "api_key") {
        Some(value) => value
        None => return @llm.ProviderBuildResult::Unconfigured
      }
      let base_setting = match kimi_setting_string(source, "base_url") {
        Some(value) => value
        None => "https://api.moonshot.ai/v1"
      }
      let (base_url, endpoint_prefix) = kimi_endpoint_parts(base_setting)
      KimiConfig::new(
        api_key,
        model~,
        base_url~,
        endpoint_prefix~,
        reasoning_effort=effort,
      )
    }
  }
  let port = KimiModelPort::new(config, ctx=self.ctx)
  @llm.ProviderBuildResult::Ready(port.model_catalog())
}

///|
pub impl @llm.RefreshableProviderFactory for KimiProvider with fn provider_id(
  _self : KimiProvider,
) -> String {
  "kimi"
}

///|
/// Explicit live model discovery.  The endpoint and response schema remain
/// provider-owned; the host only decides when to invoke this seam.
pub impl @llm.RefreshableProviderFactory for KimiProvider with fn refresh(
  self : KimiProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let model = kimi_model(source)
  let effort = kimi_effort(source)
  let credential = source.effective_credential("kimi")
  let config = match credential {
    Some(@oauth.ProviderCredential::OAuth(credential)) =>
      KimiConfig::from_oauth_credential(
        credential,
        model,
        reasoning_effort=effort,
        // Defer effort validation until the authenticated catalog is parsed.
        thinking_efforts=Some(if effort == "" { [] } else { [effort] }),
      )
    Some(@oauth.ProviderCredential::ApiKey(credential)) => {
      let base_setting = match kimi_setting_string(source, "base_url") {
        Some(value) => value
        None => "https://api.moonshot.ai/v1"
      }
      let (base_url, endpoint_prefix) = kimi_endpoint_parts(base_setting)
      KimiConfig::new(
        credential.secret,
        model~,
        base_url~,
        endpoint_prefix~,
        reasoning_effort=effort,
        thinking_efforts=Some(if effort == "" { [] } else { [effort] }),
      )
    }
    None => {
      let api_key = match kimi_setting_string(source, "api_key") {
        Some(value) => value
        None => return @llm.ProviderBuildResult::Unconfigured
      }
      let base_setting = match kimi_setting_string(source, "base_url") {
        Some(value) => value
        None => "https://api.moonshot.ai/v1"
      }
      let (base_url, endpoint_prefix) = kimi_endpoint_parts(base_setting)
      KimiConfig::new(
        api_key,
        model~,
        base_url~,
        endpoint_prefix~,
        reasoning_effort=effort,
        thinking_efforts=Some(if effort == "" { [] } else { [effort] }),
      )
    }
  }
  let models = fetch_kimi_models(
    config.base_url,
    config.api_key,
    endpoint_prefix=config.endpoint_prefix,
  ) catch {
    err =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_kimi",
        detail="Kimi model catalog refresh failed: " + err.to_string(),
      )
  }
  let port = KimiModelPort::new(config, ctx=self.ctx)
  @llm.ProviderBuildResult::Ready(port.model_catalog_from_models(models))
}

///|
pub impl @llm.OAuthFactory for KimiProvider with fn provider_id(
  _self : KimiProvider,
) -> String {
  "kimi"
}

///|
pub impl @llm.OAuthFactory for KimiProvider with fn credential_id(
  _self : KimiProvider,
) -> String {
  "kimi"
}

///|
pub impl @llm.OAuthFactory for KimiProvider with fn login(
  _self : KimiProvider,
  interaction : &@oauth.AuthInteraction,
) -> @oauth.Credential raise @oauth.OAuthError {
  let oauth = KimiOAuth::KimiOAuth()
  oauth.login(interaction)
}

///|
/// Provider-owned API-key login. The host supplies only a generic secret
/// prompt; Kimi validates and persists the resulting opaque credential.
pub impl @llm.ApiKeyFactory for KimiProvider with fn provider_id(
  _self : KimiProvider,
) -> String {
  "kimi"
}

///|
pub impl @llm.ApiKeyFactory for KimiProvider with fn credential_id(
  _self : KimiProvider,
) -> String {
  "kimi"
}

///|
pub impl @llm.ApiKeyFactory for KimiProvider with fn login(
  _self : KimiProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="Kimi API key"),
  )
  if secret.length() == 0 {
    raise @oauth.OAuthError::ParseError("Kimi API key must not be empty")
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}
