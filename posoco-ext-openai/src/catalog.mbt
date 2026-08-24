///|
/// Build the provider-owned OpenAI model catalog.
///
/// OpenAI API-key and ChatGPT/Codex OAuth model discovery stay separate all
/// the way from response parsing to slot construction.  The router receives
/// only ready model slots and opaque provider capability metadata.

///|
fn openai_api_base_url() -> String {
  "https://api.openai.com/v1"
}

///|
fn openai_api_base_for_key(config : OpenAIConfig) -> String {
  if config.base_url == codex_oauth_api_base() {
    openai_api_base_url()
  } else {
    config.base_url
  }
}

///|
fn openai_apply_effort(config : OpenAIConfig, effort : String?) -> OpenAIConfig {
  match effort {
    Some(value) => config.with_reasoning_effort(value)
    None => config
  }
}

///|
fn openai_catalog_slot(
  config : OpenAIConfig,
  oauth : &@oauth.OAuthProvider,
  api_key : &@llm.ApiKeyFactory,
  label? : String? = None,
  thinking_efforts? : Array[String] = [],
  context_window? : Int? = None,
  capabilities? : Array[String] = [],
  default_effort? : String? = None,
) -> @llm.ModelSlot {
  let port : &@posoco.ModelPort = OpenAIModelPort(config)
  let slot_id = "openai/" + config.model
  let rebuild_on_effort : ((String) -> @llm.ModelSlot)? = if thinking_efforts.is_empty() {
    None
  } else {
    Some(fn(effort) {
      let refreshed = config.with_reasoning_effort(effort)
      openai_catalog_slot(
        refreshed,
        oauth,
        api_key,
        label~,
        thinking_efforts~,
        context_window~,
        capabilities~,
        default_effort~,
      )
    })
  }
  @llm.ModelSlot::ModelSlot(
    id=slot_id,
    label=match label {
      Some(value) => value
      None => "OpenAI / " + config.model
    },
    provider_id="openai",
    model_id=config.model,
    port~,
    oauth=Some(oauth),
    api_key=Some(api_key),
    thinking_efforts~,
    context_window~,
    capabilities~,
    default_effort~,
    rebuild_on_credential=Some(fn(credential) {
      let base = OpenAIConfig::from_codex_credential(credential, config.model)
      let base = { ..base, context_window: config.context_window }
      let refreshed = openai_apply_effort(base, config.reasoning_effort)
      openai_catalog_slot(
        refreshed,
        oauth,
        api_key,
        label~,
        thinking_efforts~,
        context_window~,
        capabilities~,
        default_effort~,
      )
    }),
    rebuild_on_api_key=Some(fn(credential) {
      let base = OpenAIConfig::with_base_url(
        credential.secret,
        config.model,
        openai_api_base_for_key(config),
      )
      let base = { ..base, context_window: config.context_window }
      let refreshed = openai_apply_effort(base, config.reasoning_effort)
      openai_catalog_slot(
        refreshed,
        oauth,
        api_key,
        label~,
        thinking_efforts~,
        context_window~,
        capabilities~,
        default_effort~,
      )
    }),
    rebuild_on_effort~,
  )
}

///|
fn openai_oauth_factory() -> &@oauth.OAuthProvider {
  let implementation = CodexOAuth::CodexOAuth()
  implementation
}

///|
fn openai_api_key_factory() -> &@llm.ApiKeyFactory {
  let implementation = OpenAIProvider()
  implementation
}

///|
pub fn OpenAIModelPort::model_catalog(
  self : OpenAIModelPort,
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  let oauth = openai_oauth_factory()
  let api_key = openai_api_key_factory()
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="openai",
    slots=[openai_catalog_slot(self.config, oauth, api_key)],
    capabilities=["chat", "streaming", "api_key", "oauth"],
  )
}

///|
fn preferred_openai_models(
  models : Array[OpenAIModelInfo],
  preferred_id : String,
) -> Array[OpenAIModelInfo] {
  let result : Array[OpenAIModelInfo] = []
  let mut preferred : OpenAIModelInfo? = None
  for model in models {
    if model.id == preferred_id {
      preferred = Some(model)
    } else {
      result.push(model)
    }
  }
  match preferred {
    Some(model) => {
      let ordered : Array[OpenAIModelInfo] = [model]
      ordered.append(result)
      ordered
    }
    None => models
  }
}

///|
pub fn OpenAIModelPort::model_catalog_from_api_models(
  self : OpenAIModelPort,
  models : Array[OpenAIModelInfo],
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  if models.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_openai",
      detail="OpenAI API models endpoint returned an empty catalog",
    )
  }
  let oauth = openai_oauth_factory()
  let api_key = openai_api_key_factory()
  let slots : Array[@llm.ModelSlot] = []
  for info in preferred_openai_models(models, self.config.model) {
    let config = OpenAIConfig::with_base_url(
      self.config.api_key,
      info.id,
      self.config.base_url,
    )
    slots.push(
      openai_catalog_slot(
        config,
        oauth,
        api_key,
        label=Some(info.display_name),
        capabilities=["chat", "streaming", "api_key"],
      ),
    )
  }
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="openai",
    slots~,
    capabilities=["chat", "streaming", "api_key"],
  )
}

///|
fn preferred_codex_models(
  models : Array[CodexModelInfo],
  preferred_id : String,
) -> Array[CodexModelInfo] {
  let visible : Array[CodexModelInfo] = []
  for model in models {
    // The endpoint includes records that are hidden or not usable through the
    // Responses API.  They are metadata, not selectable model slots.
    if model.visibility == "list" && model.supported_in_api {
      visible.push(model)
    }
  }
  let result : Array[CodexModelInfo] = []
  let mut preferred : CodexModelInfo? = None
  for model in visible {
    if model.slug == preferred_id {
      preferred = Some(model)
    } else {
      result.push(model)
    }
  }
  match preferred {
    Some(model) => {
      let ordered : Array[CodexModelInfo] = [model]
      ordered.append(result)
      ordered
    }
    None => result
  }
}

///|
fn codex_model_efforts(info : CodexModelInfo) -> Array[String] {
  info.supported_reasoning_levels.map(fn(level) { level.effort })
}

///|
fn codex_catalog_slot_from_info(
  base_config : OpenAIConfig,
  info : CodexModelInfo,
  oauth : &@oauth.OAuthProvider,
  api_key : &@llm.ApiKeyFactory,
) -> @llm.ModelSlot {
  let efforts = codex_model_efforts(info)
  let selected_effort = match base_config.reasoning_effort {
    Some(value) if efforts.contains(value) => Some(value)
    _ => info.default_reasoning_level
  }
  let config = OpenAIConfig::with_base_url(
    base_config.api_key,
    info.slug,
    codex_oauth_api_base(),
  )
  let config = {
    ..config,
    account_id: base_config.account_id,
    reasoning_effort: selected_effort,
    context_window: info.context_window,
  }
  let capabilities : Array[String] = ["chat", "streaming", "oauth"]
  if !efforts.is_empty() {
    capabilities.push("reasoning")
  }
  openai_catalog_slot(
    config,
    oauth,
    api_key,
    label=Some(info.display_name),
    thinking_efforts=efforts,
    context_window=info.context_window,
    capabilities~,
    default_effort=info.default_reasoning_level,
  )
}

///|
pub fn OpenAIModelPort::model_catalog_from_codex_models(
  self : OpenAIModelPort,
  models : Array[CodexModelInfo],
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  let visible = preferred_codex_models(models, self.config.model)
  if visible.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_openai",
      detail="Codex models endpoint returned no selectable models",
    )
  }
  let oauth = openai_oauth_factory()
  let api_key = openai_api_key_factory()
  let slots : Array[@llm.ModelSlot] = []
  let mut has_reasoning = false
  for info in visible {
    if !info.supported_reasoning_levels.is_empty() {
      has_reasoning = true
    }
    slots.push(codex_catalog_slot_from_info(self.config, info, oauth, api_key))
  }
  let capabilities : Array[String] = ["chat", "streaming", "oauth"]
  if has_reasoning {
    capabilities.push("reasoning")
  }
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="openai",
    slots~,
    capabilities~,
  )
}
