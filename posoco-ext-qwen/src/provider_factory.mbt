///|
pub(all) struct QwenProvider {
  ctx : @devkit.ExtContext
}

///|
pub fn QwenProvider::QwenProvider(
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> QwenProvider {
  { ctx, }
}

///|
fn qwen_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_qwen",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_qwen",
        detail="setting must be a string: " + key,
      )
  }
}

///|
fn qwen_setting_bool(
  source : @llm.ProviderConfigSource,
  key : String,
) -> Bool? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::True) => Some(true)
    Some(Json::False) => Some(false)
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_qwen",
        detail="setting must be a boolean: " + key,
      )
  }
}

///|
fn qwen_setting_context_window(
  source : @llm.ProviderConfigSource,
) -> Int? raise @posoco.CompositionError {
  match source.setting("context_window") {
    None => None
    Some(Json::Number(value, ..)) => {
      if value != value.floor() {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_qwen",
          detail="setting must be a whole number: context_window",
        )
      }
      let window = value.to_int()
      if window <= 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_qwen",
          detail="setting must be positive: context_window",
        )
      }
      Some(window)
    }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_qwen",
        detail="setting must be a number: context_window",
      )
  }
}

///|
fn qwen_build_config(
  source : @llm.ProviderConfigSource,
) -> QwenConfig? raise @posoco.CompositionError {
  let credential = source.effective_credential("qwen")
  let api_key = match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_qwen",
        detail="qwen has no OAuth in this extension; use an Alibaba Cloud API key",
      )
    Some(@oauth.ProviderCredential::ApiKey(credential)) => credential.secret
    None =>
      match qwen_setting_string(source, "api_key") {
        Some(value) => value
        None => return None
      }
  }
  let base_url = match qwen_setting_string(source, "base_url") {
    Some(value) => value
    None => "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
  }
  let endpoint_prefix = match qwen_setting_string(source, "endpoint_prefix") {
    Some(value) => value
    None => ""
  }
  let model = match qwen_setting_string(source, "model") {
    Some(value) => value
    None => "qwen3.8-max"
  }
  let reasoning_effort = qwen_setting_string(source, "reasoning_effort")
  let enable_thinking = qwen_setting_bool(source, "enable_thinking")
  if reasoning_effort is Some(_) && enable_thinking is Some(_) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_qwen",
      detail="reasoning_effort and enable_thinking are mutually exclusive",
    )
  }
  let config = QwenConfig(
    api_key,
    base_url~,
    model~,
    endpoint_prefix~,
    reasoning_effort~,
    enable_thinking~,
    preserve_thinking=qwen_setting_bool(source, "preserve_thinking"),
    tool_stream=qwen_setting_bool(source, "tool_stream"),
    supports_images=qwen_setting_bool(source, "image_input"),
    context_window=qwen_setting_context_window(source),
  )
  Some(config)
}

///|
pub impl @llm.ProviderFactory for QwenProvider with fn provider_id(
  _self : QwenProvider,
) -> String {
  "qwen"
}

///|
pub impl @llm.ProviderFactory for QwenProvider with fn credential_id(
  _self : QwenProvider,
) -> String {
  "qwen"
}

///|
pub extend QwenProvider with @posoco/ext-llm.ProviderFactory::{
  credential_id,
  provider_id,
  build,
}

///|
pub impl @llm.ProviderFactory for QwenProvider with fn build(
  self : QwenProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  match qwen_build_config(source) {
    Some(config) =>
      @llm.ProviderBuildResult::Ready(
        @llm.ProviderModelCatalog::ProviderModelCatalog(
          provider_id="qwen",
          slots=[qwen_catalog_slot(config, self.ctx)],
          capabilities=["chat", "streaming", "api_key"],
        ),
      )
    None => @llm.ProviderBuildResult::Unconfigured
  }
}

///|
pub impl @llm.ApiKeyFactory for QwenProvider with fn provider_id(
  _self : QwenProvider,
) -> String {
  "qwen"
}

///|
pub impl @llm.ApiKeyFactory for QwenProvider with fn credential_id(
  _self : QwenProvider,
) -> String {
  "qwen"
}

///|
pub extend QwenProvider with @posoco/ext-llm.ApiKeyFactory::{login}

///|
pub impl @llm.ApiKeyFactory for QwenProvider with fn login(
  _self : QwenProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="Alibaba Cloud Qwen API key"),
  )
  if secret.length() == 0 {
    raise @oauth.OAuthError::ParseError("Qwen API key must not be empty")
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}
