///|
/// The picker-facing effort list: an implicit leading "off" (thinking
/// disabled on the wire) plus the uniform provider ladder.
fn deepseek_slot_efforts() -> Array[String] {
  let efforts : Array[String] = ["off"]
  efforts.append(deepseek_reasoning_efforts().copy())
  efforts
}

///|
/// The picker-facing label of the config's current effort.
fn deepseek_effort_label(config : DeepSeekConfig) -> String {
  if config.reasoning_effort == "" {
    "off"
  } else {
    config.reasoning_effort
  }
}

///|
fn deepseek_catalog_slot(
  config : DeepSeekConfig,
  ctx : @devkit.ExtContext,
  api_key : &@provider.ApiKeyFactory,
) -> @provider.ModelSlot {
  let port : &@posoco.ModelPort = DeepSeekModelPort(config, ctx~)
  let slot_id = "deepseek/" + config.model
  let slot_efforts = deepseek_slot_efforts()
  let default_effort = Some(deepseek_effort_label(config))
  let rebuild_on_effort : (String) -> @provider.ModelSlot = fn(effort) {
    let rebuilt_config = config.with_reasoning_effort(effort) catch {
      err => abort("DeepSeek catalog effort rebuild failed: " + err.to_string())
    }
    deepseek_catalog_slot(rebuilt_config, ctx, api_key)
  }
  let slot = @provider.ModelSlot::ModelSlot(
    id=slot_id,
    label="DeepSeek / " + config.model,
    provider_id="deepseek",
    model_id=config.model,
    port~,
    api_key=Some(api_key),
    thinking_efforts=slot_efforts,
    default_effort~,
    context_window=config.context_window,
    context_window_source="configured",
    capabilities=if config.supports_images { ["image_in"] } else { [] },
    rebuild_on_api_key=Some(fn(credential) {
      let rebuilt_config = DeepSeekConfig(
        credential.secret,
        model=config.model,
        base_url=config.base_url,
        endpoint_prefix=config.endpoint_prefix,
        reasoning_effort=config.reasoning_effort,
        context_window=config.context_window,
        max_reasoning_chars=config.max_reasoning_chars,
        recover_on_reasoning_exhaustion=config.recover_on_reasoning_exhaustion,
        repeated_reasoning_span_chars=config.repeated_reasoning_span_chars,
        supports_images=config.supports_images,
      )
      deepseek_catalog_slot(rebuilt_config, ctx, api_key)
    }),
    rebuild_on_effort=Some(rebuild_on_effort),
  )
  slot
}

///|
/// Build one slot from a provider-discovered model record. The configured
/// effort carries over verbatim — every DeepSeek model accepts the same
/// ladder, and an explicitly configured off (empty effort) means thinking is
/// disabled on the wire.
fn deepseek_catalog_slot_from_info(
  base_config : DeepSeekConfig,
  info : DeepSeekModelInfo,
  ctx : @devkit.ExtContext,
  api_key : &@provider.ApiKeyFactory,
) -> @provider.ModelSlot {
  let config = DeepSeekConfig(
    base_config.api_key,
    model=info.id,
    base_url=base_config.base_url,
    endpoint_prefix=base_config.endpoint_prefix,
    reasoning_effort=base_config.reasoning_effort,
    context_window=if info.id == base_config.model {
      base_config.context_window
    } else {
      None
    },
    max_reasoning_chars=base_config.max_reasoning_chars,
    recover_on_reasoning_exhaustion=base_config.recover_on_reasoning_exhaustion,
    repeated_reasoning_span_chars=base_config.repeated_reasoning_span_chars,
    // The image opt-in describes the configured model; discovered sibling
    // models must not inherit its image_in advertisement (same scoping as
    // the configured context_window above).
    supports_images=info.id == base_config.model && base_config.supports_images,
  )
  deepseek_catalog_slot(config, ctx, api_key)
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
) -> @provider.ProviderModelCatalog raise @posoco.CompositionError {
  let api_key_impl = DeepSeekProvider(ctx=self.ctx)
  let api_key : &@provider.ApiKeyFactory = api_key_impl
  @provider.ProviderModelCatalog::ProviderModelCatalog(
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
) -> @provider.ProviderModelCatalog raise @posoco.CompositionError {
  if models.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_deepseek",
      detail="models endpoint returned an empty catalog",
    )
  }
  let api_key_impl = DeepSeekProvider(ctx=self.ctx)
  let api_key : &@provider.ApiKeyFactory = api_key_impl
  let slots : Array[@provider.ModelSlot] = []
  for info in deepseek_preferred_models(models, self.config.model) {
    slots.push(
      deepseek_catalog_slot_from_info(self.config, info, self.ctx, api_key),
    )
  }
  @provider.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="deepseek",
    slots~,
    capabilities=["chat", "streaming", "fim", "prefix", "api_key"],
  )
}
