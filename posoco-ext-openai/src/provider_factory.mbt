///| 
/// Provider-owned configuration and OAuth contribution for OpenAI/Codex.

///|
pub(all) struct OpenAIProvider {
  models_transport : &OpenAIModelsHttpTransport?
}

///|
pub fn OpenAIProvider::new(
  transport? : &OpenAIModelsHttpTransport? = None,
) -> OpenAIProvider {
  OpenAIProvider::{ models_transport: transport }
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
pub impl @llm.ProviderFactory for OpenAIProvider with fn provider_id(
  _self : OpenAIProvider,
) -> String {
  "openai"
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
pub impl @llm.ProviderFactory for OpenAIProvider with fn build(
  _self : OpenAIProvider,
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
        None => OpenAIConfig::new(credential.secret, model)
      }
    None => {
      let api_key = match openai_setting_string(source, "api_key") {
        Some(value) => value
        None => return @llm.ProviderBuildResult::Unconfigured
      }
      match openai_setting_string(source, "base_url") {
        Some(base_url) => OpenAIConfig::with_base_url(api_key, model, base_url)
        None => OpenAIConfig::new(api_key, model)
      }
    }
  }
  let port = OpenAIModelPort::new(config)
  @llm.ProviderBuildResult::Ready(port.model_catalog())
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
      let config = OpenAIConfig::from_codex_credential(credential, model)
      let config = openai_apply_effort(config, requested_effort)
      let account_id = match config.account_id {
        Some(value) if value.length() > 0 => value
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_openai",
            detail="Codex model refresh requires account_id credential metadata",
          )
      }
      let transport_impl = match self.models_transport {
        Some(value) => value
        None => {
          let default_transport = DefaultOpenAIModelsHttpTransport::DefaultOpenAIModelsHttpTransport()
          let transport : &OpenAIModelsHttpTransport = default_transport
          transport
        }
      }
      let models = fetch_codex_models_with_transport(
        transport_impl,
        codex_oauth_api_base(),
        config.api_key,
        account_id,
        openai_codex_models_client_version(),
      ) catch {
        err =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_openai",
            detail="Codex model catalog refresh failed: " + err.to_string(),
          )
      }
      let port = OpenAIModelPort::new(config)
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
      let port = OpenAIModelPort::new(config)
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
      let port = OpenAIModelPort::new(config)
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
