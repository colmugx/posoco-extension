///|
pub(all) struct OpenRouterProvider {
  ctx : @devkit.ExtContext
  /// Provider-scoped process-local compatibility knowledge. Every catalog and
  /// port rebuilt by this factory shares the same rejection state.
  prompt_cache_key_rejection_state : Ref[Bool]
}

///|
/// The optional `ctx` is carried for debug logging at composition seams.
pub fn OpenRouterProvider::OpenRouterProvider(
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> OpenRouterProvider {
  { ctx, prompt_cache_key_rejection_state: Ref(false), }
}

///|
fn openrouter_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openrouter",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail="setting must be a string: " + key,
      )
  }
}

///|
fn openrouter_setting_bool(
  source : @llm.ProviderConfigSource,
  key : String,
) -> Bool raise @posoco.CompositionError {
  match source.setting(key) {
    None => false
    Some(Json::True) => true
    Some(Json::False) => false
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail="setting must be a boolean: " + key,
      )
  }
}

///|
fn openrouter_effort_array_value(
  key : String,
  values : Array[Json],
) -> Array[String] raise @posoco.CompositionError {
  let efforts : Array[String] = []
  for value in values {
    match value {
      Json::String(effort) if effort.length() > 0 => efforts.push(effort)
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openrouter",
          detail=key + " entries must be non-empty strings",
        )
    }
  }
  let seen : Map[String, Unit] = Map::from_array([])
  for effort in efforts {
    if effort == "off" || effort == "on" {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail=key +
          " reserves 'off'/'on' for the thinking toggle; declare explicit levels instead",
      )
    }
    if seen.contains(effort) {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail=key + " entries must be unique: " + effort,
      )
    }
    seen[effort] = ()
  }
  efforts
}

///|
fn openrouter_setting_effort_array(
  source : @llm.ProviderConfigSource,
  key : String,
) -> Array[String]? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::Array(values)) =>
      Some(openrouter_effort_array_value(key, values))
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail=key + " must be an array of strings",
      )
  }
}

///|
fn openrouter_slot_efforts(config : OpenRouterConfig) -> Array[String] {
  if config.thinking_efforts.is_empty() {
    return ["off", "on"]
  }
  let efforts : Array[String] = ["off"]
  efforts.append(config.thinking_efforts.copy())
  efforts
}

///|
fn openrouter_effort_label(config : OpenRouterConfig) -> String {
  if config.thinking == false {
    "off"
  } else {
    match config.reasoning_effort {
      Some(effort) => effort
      None => "on"
    }
  }
}

///|
/// All rebuild hooks funnel back here and retain both the explicit cache-key
/// policy and the provider-scoped rejection state.
fn openrouter_catalog_slot(
  config : OpenRouterConfig,
  api_key : &@llm.ApiKeyFactory,
  prompt_cache_key_rejection_state : Ref[Bool],
) -> @llm.ModelSlot {
  let slot_id = "openrouter/" + config.model
  let label = "openrouter / " + config.model
  let slot_efforts = openrouter_slot_efforts(config)
  let default_effort = Some(openrouter_effort_label(config))
  let port : &@posoco.ModelPort = openrouter_model_port_with_prompt_cache_rejection_state(
    config, prompt_cache_key_rejection_state,
  )
  let rebuild_on_effort : ((String) -> @llm.ModelSlot)? = Some(fn(effort) {
    let rebuilt_config = config.with_reasoning_effort(effort) catch {
      err =>
        abort("openrouter catalog effort rebuild failed: " + err.to_string())
    }
    openrouter_catalog_slot(
      rebuilt_config, api_key, prompt_cache_key_rejection_state,
    )
  })
  let capabilities : Array[String] = ["chat", "streaming", "api_key"]
  if !slot_efforts.is_empty() || config.thinking {
    capabilities.push("reasoning")
  }
  if config.supports_images {
    capabilities.push("image_in")
  }
  @llm.ModelSlot::ModelSlot(
    id=slot_id,
    label~,
    provider_id="openrouter",
    model_id=config.model,
    port~,
    api_key=Some(api_key),
    thinking_efforts=slot_efforts,
    context_window=config.context_window,
    capabilities~,
    default_effort~,
    rebuild_on_api_key=Some(fn(credential) {
      let rebuilt_config = OpenRouterConfig(
        credential.secret,
        model=config.model,
        base_url=config.base_url,
        thinking=config.thinking,
        reasoning_effort=config.reasoning_effort,
        thinking_efforts=config.thinking_efforts,
        context_window=config.context_window,
        compact_threshold=config.compact_threshold,
        supports_images=config.supports_images,
        http_referer=config.http_referer,
        title=config.title,
        send_prompt_cache_key=config.send_prompt_cache_key,
      )
      openrouter_catalog_slot(
        rebuilt_config, api_key, prompt_cache_key_rejection_state,
      )
    }),
    rebuild_on_effort~,
  )
}

///|
pub impl @llm.ProviderFactory for OpenRouterProvider with fn provider_id(
  _self : OpenRouterProvider,
) -> String {
  "openrouter"
}

///|
pub impl @llm.ProviderFactory for OpenRouterProvider with fn credential_id(
  _self : OpenRouterProvider,
) -> String {
  "openrouter"
}

///|
fn openrouter_resolve_api_key(
  source : @llm.ProviderConfigSource,
) -> String? raise @posoco.CompositionError {
  let credential = source.effective_credential("openrouter")
  match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail="OAuth credential is not supported for provider openrouter",
      )
    Some(@oauth.ProviderCredential::ApiKey(credential)) =>
      Some(credential.secret)
    None => openrouter_setting_string(source, "api_key")
  }
}

///|
fn openrouter_resolve_base_url(
  source : @llm.ProviderConfigSource,
) -> String raise @posoco.CompositionError {
  match openrouter_setting_string(source, "base_url") {
    Some(value) => value
    None => "https://openrouter.ai/api/v1"
  }
}

///|
fn openrouter_resolve_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  openrouter_setting_string(source, key)
}

///|
pub impl @llm.ProviderFactory for OpenRouterProvider with fn build(
  self : OpenRouterProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let api_key = match openrouter_resolve_api_key(source) {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let base_url = openrouter_resolve_base_url(source)
  let http_referer = openrouter_setting_string(source, "http_referer")
  let title = openrouter_setting_string(source, "title")
  let send_prompt_cache_key = openrouter_setting_bool(
    source, "send_prompt_cache_key",
  )
  let api_key_factory : &@llm.ApiKeyFactory = OpenRouterApiKeyFactory(
    ctx=self.ctx,
  )
  match parse_cached_openrouter_models(source.cached_models) {
    Some(models) => {
      let preferred = match openrouter_setting_string(source, "model") {
        Some(value) => value
        None => ""
      }
      let catalog = openrouter_model_catalog_with_cache_policy(
        api_key,
        base_url,
        models,
        preferred,
        api_key_factory,
        self.prompt_cache_key_rejection_state,
        send_prompt_cache_key,
        http_referer~,
        title~,
      )
      return @llm.ProviderBuildResult::Ready(catalog)
    }
    None => ()
  }
  let model = match openrouter_setting_string(source, "model") {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let declared_efforts = match
    openrouter_setting_effort_array(source, "thinking_efforts") {
    Some(values) => values
    None => []
  }
  let context_window = match source.setting("context_window") {
    None => None
    Some(Json::Number(value, ..)) => {
      let window = value.to_int()
      if window.to_double() != value || window <= 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openrouter",
          detail="context_window must be a positive integer",
        )
      }
      Some(window)
    }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail="context_window must be a positive integer",
      )
  }
  let compact_threshold = match source.setting("compact_threshold") {
    None => None
    Some(Json::Number(value, ..)) => {
      if value <= 0.0 || value > 1.0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openrouter",
          detail="compact_threshold must be a fraction in (0, 1] (e.g. 0.85)",
        )
      }
      if context_window is None {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openrouter",
          detail="compact_threshold requires context_window",
        )
      }
      Some(value)
    }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail="compact_threshold must be a number in (0, 1]",
      )
  }
  let config = match declared_efforts.length() {
    0 =>
      OpenRouterConfig(
        api_key,
        model~,
        base_url~,
        context_window~,
        compact_threshold~,
        http_referer~,
        title~,
        send_prompt_cache_key~,
      )
    _ =>
      OpenRouterConfig(
        api_key,
        model~,
        base_url~,
        thinking=true,
        reasoning_effort=Some(declared_efforts[0]),
        thinking_efforts=declared_efforts,
        context_window~,
        compact_threshold~,
        http_referer~,
        title~,
        send_prompt_cache_key~,
      )
  }
  @llm.ProviderBuildResult::Ready(
    @llm.ProviderModelCatalog::ProviderModelCatalog(
      provider_id="openrouter",
      slots=[
        openrouter_catalog_slot(
          config,
          api_key_factory,
          self.prompt_cache_key_rejection_state,
        ),
      ],
      capabilities=["chat", "streaming", "reasoning", "api_key"],
    ),
  )
}

///|
pub impl @llm.RefreshableProviderFactory for OpenRouterProvider with fn provider_id(
  _self : OpenRouterProvider,
) -> String {
  "openrouter"
}

///|
pub(all) struct OpenRouterApiKeyFactory {
  ctx : @devkit.ExtContext
}

///|
pub fn OpenRouterApiKeyFactory::OpenRouterApiKeyFactory(
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> OpenRouterApiKeyFactory {
  { ctx, }
}

///|
pub impl @llm.ApiKeyFactory for OpenRouterApiKeyFactory with fn provider_id(
  _self : OpenRouterApiKeyFactory,
) -> String {
  "openrouter"
}

///|
pub impl @llm.ApiKeyFactory for OpenRouterApiKeyFactory with fn credential_id(
  _self : OpenRouterApiKeyFactory,
) -> String {
  "openrouter"
}

///|
pub impl @llm.ApiKeyFactory for OpenRouterApiKeyFactory with fn login(
  _self : OpenRouterApiKeyFactory,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="OpenRouter API key"),
  )
  if secret.length() == 0 {
    raise @oauth.OAuthError::ParseError("OpenRouter API key must not be empty")
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}
