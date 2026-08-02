///|
fn deepseek_catalog_slot(
  config : DeepSeekConfig,
  ctx : @devkit.ExtContext,
  api_key : &@llm.ApiKeyFactory,
  default_effort? : String? = None,
) -> @llm.ModelSlot {
  let port : &@posoco.ModelPort = DeepSeekModelPort::new(config, ctx~)
  let slot_id = "deepseek/" + config.model
  let rebuild_on_effort : ((String) -> @llm.ModelSlot)? = if config.thinking_efforts.is_empty() {
    None
  } else {
    Some(fn(effort) {
      let rebuilt_config = config.with_reasoning_effort(effort) catch {
        err =>
          abort("DeepSeek catalog effort rebuild failed: " + err.to_string())
      }
      deepseek_catalog_slot(rebuilt_config, ctx, api_key, default_effort~)
    })
  }
  let slot = @llm.ModelSlot::ModelSlot(
    id=slot_id,
    label="DeepSeek / " + config.model,
    provider_id="deepseek",
    model_id=config.model,
    port~,
    api_key=Some(api_key),
    thinking_efforts=config.thinking_efforts,
    default_effort~,
    rebuild_on_api_key=Some(fn(credential) {
      let rebuilt_config = DeepSeekConfig::new(
        credential.secret,
        model=config.model,
        base_url=config.base_url,
        endpoint_prefix=config.endpoint_prefix,
        reasoning_effort=config.reasoning_effort,
        thinking_efforts=config.thinking_efforts,
      )
      deepseek_catalog_slot(rebuilt_config, ctx, api_key, default_effort~)
    }),
    rebuild_on_effort~,
  )
  slot
}

///|
/// Build one slot from a provider-discovered model record.  The selected
/// effort is kept only when the server-derived descriptor still advertises it;
/// otherwise the descriptor's default is used, or no thinking effort is sent
/// for a non-reasoning model.
fn deepseek_catalog_slot_from_info(
  base_config : DeepSeekConfig,
  info : DeepSeekModelInfo,
  ctx : @devkit.ExtContext,
  api_key : &@llm.ApiKeyFactory,
) -> @llm.ModelSlot {
  let selected_effort = if info.thinking_efforts.is_empty() {
    ""
  } else if info.thinking_efforts.contains(base_config.reasoning_effort) {
    base_config.reasoning_effort
  } else {
    match info.default_effort {
      Some(value) => value
      None => info.thinking_efforts[0]
    }
  }
  let config = DeepSeekConfig::new(
    base_config.api_key,
    model=info.id,
    base_url=base_config.base_url,
    endpoint_prefix=base_config.endpoint_prefix,
    reasoning_effort=selected_effort,
    thinking_efforts=info.thinking_efforts,
  )
  deepseek_catalog_slot(
    config,
    ctx,
    api_key,
    default_effort=info.default_effort,
  )
}

///|
/// Keep the configured model first after a live refresh while preserving the
/// provider's server order for all remaining models.
fn deepseek_preferred_models(
  models : Array[DeepSeekModelInfo],
  preferred_id : String,
) -> Array[DeepSeekModelInfo] {
  let result : Array[DeepSeekModelInfo] = []
  let mut preferred : DeepSeekModelInfo? = None
  for model in models {
    if model.id == preferred_id {
      preferred = Some(model)
    } else {
      result.push(model)
    }
  }
  match preferred {
    Some(model) => {
      let ordered : Array[DeepSeekModelInfo] = [model]
      ordered.append(result)
      ordered
    }
    None => models
  }
}

///|
/// Build the provider-owned model catalog for DeepSeek.
///
/// Endpoint and request-shape decisions remain inside this extension. Cetas
/// only receives a ready-to-compose catalog and never parses DeepSeek config.
pub fn DeepSeekModelPort::model_catalog(
  self : DeepSeekModelPort,
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  let api_key_impl = DeepSeekProvider::new(ctx=self.ctx)
  let api_key : &@llm.ApiKeyFactory = api_key_impl
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="deepseek",
    slots=[deepseek_catalog_slot(self.config, self.ctx, api_key)],
    capabilities=["chat", "streaming", "fim", "prefix", "api_key"],
  )
}

///|
/// Build a catalog from the provider's live `/models` response.
pub fn DeepSeekModelPort::model_catalog_from_models(
  self : DeepSeekModelPort,
  models : Array[DeepSeekModelInfo],
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  if models.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_deepseek",
      detail="models endpoint returned an empty catalog",
    )
  }
  let api_key_impl = DeepSeekProvider::new(ctx=self.ctx)
  let api_key : &@llm.ApiKeyFactory = api_key_impl
  let slots : Array[@llm.ModelSlot] = []
  for info in deepseek_preferred_models(models, self.config.model) {
    slots.push(
      deepseek_catalog_slot_from_info(self.config, info, self.ctx, api_key),
    )
  }
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="deepseek",
    slots~,
    capabilities=["chat", "streaming", "fim", "prefix", "api_key"],
  )
}
