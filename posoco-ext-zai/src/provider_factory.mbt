///|
pub(all) struct ZaiProvider {
  ctx : @devkit.ExtContext
}

///|
pub fn ZaiProvider::ZaiProvider(
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> ZaiProvider {
  { ctx, }
}

///|
fn zai_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_zai",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_zai",
        detail="setting must be a string: " + key,
      )
  }
}

///|
/// Split a custom base_url into (host, path_prefix); a bare host gets the
/// profile's default prefix.
fn zai_endpoint_parts(
  url : String,
  default_prefix : String,
) -> (String, String) {
  match url.find("://") {
    None => (url, default_prefix)
    Some(protocol_end) => {
      let after_start = protocol_end + 3
      let after = url.sub(start=after_start)
      match after.find("/") {
        None => (url, default_prefix)
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
/// Resolve (base_url, endpoint_prefix, profile) from settings. `base_url`
/// overrides the profile; a custom url with no path keeps the profile prefix.
fn zai_resolve_endpoint(
  source : @llm.ProviderConfigSource,
) -> (String, String) raise @posoco.CompositionError {
  let profile = match zai_setting_string(source, "profile") {
    Some(value) => value
    None => "coding"
  }
  let (default_base, default_prefix) = match zai_profile_endpoint(profile) {
    Some(parts) => parts
    None =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_zai",
        detail="unknown profile: " +
          profile +
          " (expected coding | general | cn | cn_coding)",
      )
  }
  match zai_setting_string(source, "base_url") {
    Some(url) => zai_endpoint_parts(url, default_prefix)
    None => (default_base, default_prefix)
  }
}

///|
pub impl @llm.ProviderFactory for ZaiProvider with fn provider_id(
  _self : ZaiProvider,
) -> String {
  "zai"
}

///|
pub impl @llm.ProviderFactory for ZaiProvider with fn credential_id(
  _self : ZaiProvider,
) -> String {
  "zai"
}

///|
/// z.ai exposes no OAuth for API access — keys are created in the console
/// (Bearer, or the `id.secret` form). An OAuth credential is a typed
/// composition failure, not a silent downgrade.
pub impl @llm.ProviderFactory for ZaiProvider with fn build(
  self : ZaiProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let credential = source.effective_credential("zai")
  let api_key = match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_zai",
        detail="z.ai has no OAuth; use an API key from z.ai/model-api",
      )
    Some(@oauth.ProviderCredential::ApiKey(credential)) => credential.secret
    None =>
      match zai_setting_string(source, "api_key") {
        Some(value) => value
        None => return @llm.ProviderBuildResult::Unconfigured
      }
  }
  let model = match zai_setting_string(source, "model") {
    Some(value) => value
    None => "glm-5.3"
  }
  let (base_url, endpoint_prefix) = zai_resolve_endpoint(source)
  let config = ZaiConfig::for_model(api_key, model, base_url~, endpoint_prefix~)
  let requested_effort = zai_setting_string(source, "reasoning_effort")
  let config = match requested_effort {
    None => config
    Some(effort) => config.with_reasoning_effort(effort)
  }
  let port = ZaiModelPort(config, ctx=self.ctx)
  @llm.ProviderBuildResult::Ready(port.model_catalog())
}

///|
pub impl @llm.ApiKeyFactory for ZaiProvider with fn provider_id(
  _self : ZaiProvider,
) -> String {
  "zai"
}

///|
pub impl @llm.ApiKeyFactory for ZaiProvider with fn credential_id(
  _self : ZaiProvider,
) -> String {
  "zai"
}

///|
pub impl @llm.ApiKeyFactory for ZaiProvider with fn login(
  _self : ZaiProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="Z.ai API key"),
  )
  if secret.length() == 0 {
    raise @oauth.OAuthError::ParseError("Z.ai API key must not be empty")
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}
