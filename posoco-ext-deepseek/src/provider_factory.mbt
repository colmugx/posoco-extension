///| 
/// Provider-owned configuration source and catalog contribution.

///|
pub(all) struct DeepSeekProvider {
  ctx : @devkit.ExtContext
}

///|
pub fn DeepSeekProvider::new(
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> DeepSeekProvider {
  { ctx, }
}

///|
fn deepseek_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_deepseek",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="setting must be a string: " + key,
      )
  }
}

///|
/// Keep URL parsing in the provider extension. The host passes one opaque
/// base_url string; DeepSeek decides how its path prefix maps to chat/FIM.
fn deepseek_endpoint_parts(url : String) -> (String, String) {
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
pub impl @llm.ProviderFactory for DeepSeekProvider with fn provider_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
pub impl @llm.ProviderFactory for DeepSeekProvider with fn credential_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
pub impl @llm.ProviderFactory for DeepSeekProvider with fn build(
  self : DeepSeekProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let credential = source.effective_credential("deepseek")
  let api_key = match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="OAuth credential is not supported for provider deepseek",
      )
    Some(@oauth.ProviderCredential::ApiKey(credential)) => credential.secret
    None =>
      match deepseek_setting_string(source, "api_key") {
        Some(value) => value
        None => return @llm.ProviderBuildResult::Unconfigured
      }
  }
  let model = match deepseek_setting_string(source, "model") {
    Some(value) => value
    None => "deepseek-v4-flash"
  }
  let base_url_setting = match deepseek_setting_string(source, "base_url") {
    Some(value) => value
    None => "https://api.deepseek.com"
  }
  let (base_url, endpoint_prefix) = deepseek_endpoint_parts(base_url_setting)
  let effort = match deepseek_setting_string(source, "reasoning_effort") {
    Some("off") => ""
    Some(value) => value
    None => "high"
  }
  if effort != "" && effort != "high" && effort != "max" {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_deepseek",
      detail="unsupported reasoning_effort: " + effort,
    )
  }
  let config = DeepSeekConfig::new(
    api_key,
    model~,
    base_url~,
    endpoint_prefix~,
    reasoning_effort=effort,
  )
  let port = DeepSeekModelPort::new(config, ctx=self.ctx)
  @llm.ProviderBuildResult::Ready(port.model_catalog())
}

///|
pub impl @llm.RefreshableProviderFactory for DeepSeekProvider with fn provider_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
/// Explicit live model discovery. Unlike `build`, this path performs exactly
/// one authenticated `/models` request and fails composition on transport or
/// schema errors; it never falls back to the configured static model.
pub impl @llm.RefreshableProviderFactory for DeepSeekProvider with fn refresh(
  self : DeepSeekProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let credential = source.effective_credential("deepseek")
  let api_key = match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="OAuth credential is not supported for provider deepseek",
      )
    Some(@oauth.ProviderCredential::ApiKey(value)) => value.secret
    None =>
      match deepseek_setting_string(source, "api_key") {
        Some(value) => value
        None => return @llm.ProviderBuildResult::Unconfigured
      }
  }
  let model = match deepseek_setting_string(source, "model") {
    Some(value) => value
    None => "deepseek-v4-flash"
  }
  let base_setting = match deepseek_setting_string(source, "base_url") {
    Some(value) => value
    None => "https://api.deepseek.com"
  }
  let (base_url, endpoint_prefix) = deepseek_endpoint_parts(base_setting)
  let requested_effort = match
    deepseek_setting_string(source, "reasoning_effort") {
    Some("off") => ""
    Some(value) => value
    None => "high"
  }
  // Keep live refresh validation identical to the static build path.  In
  // particular, an unknown configured effort is a typed composition failure,
  // not the abort emitted by DeepSeekConfig::new for an invalid value.
  if requested_effort != "" &&
    requested_effort != "high" &&
    requested_effort != "max" {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_deepseek",
      detail="unsupported reasoning_effort: " + requested_effort,
    )
  }
  let config = DeepSeekConfig::new(
    api_key,
    model~,
    base_url~,
    endpoint_prefix~,
    reasoning_effort=requested_effort,
  )
  let models = fetch_deepseek_models(
    config.base_url,
    config.api_key,
    endpoint_prefix=config.endpoint_prefix,
  ) catch {
    err =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="DeepSeek model catalog refresh failed: " + err.to_string(),
      )
  }
  let port = DeepSeekModelPort::new(config, ctx=self.ctx)
  @llm.ProviderBuildResult::Ready(port.model_catalog_from_models(models))
}

///|
/// Provider-owned API-key login. The host supplies only a provider-neutral
/// secret prompt; validation and credential shape stay in this extension.
pub impl @llm.ApiKeyFactory for DeepSeekProvider with fn provider_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
pub impl @llm.ApiKeyFactory for DeepSeekProvider with fn credential_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
pub impl @llm.ApiKeyFactory for DeepSeekProvider with fn login(
  _self : DeepSeekProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="DeepSeek API key"),
  )
  if secret.length() == 0 {
    raise @oauth.OAuthError::ParseError("DeepSeek API key must not be empty")
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}
