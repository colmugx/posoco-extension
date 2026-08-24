///|
fn zai_slot_efforts(config : ZaiConfig) -> Array[String] {
  if config.thinking_efforts.is_empty() {
    return []
  }
  let efforts : Array[String] = ["off"]
  efforts.append(config.thinking_efforts.copy())
  efforts
}

///|
fn zai_effort_label(config : ZaiConfig) -> String {
  if config.reasoning_effort == "" {
    "off"
  } else {
    config.reasoning_effort
  }
}

///|
fn zai_catalog_slot(
  config : ZaiConfig,
  ctx : @devkit.ExtContext,
  api_key : &@llm.ApiKeyFactory,
) -> @llm.ModelSlot {
  let port : &@posoco.ModelPort = ZaiModelPort(config, ctx~)
  let slot_efforts = zai_slot_efforts(config)
  let default_effort = if slot_efforts.is_empty() {
    None
  } else {
    Some(zai_effort_label(config))
  }
  let rebuild_on_effort : ((String) -> @llm.ModelSlot)? = if slot_efforts.is_empty() {
    None
  } else {
    Some(fn(effort) {
      let rebuilt = config.with_reasoning_effort(effort) catch {
        err => abort("zai catalog effort rebuild failed: " + err.to_string())
      }
      zai_catalog_slot(rebuilt, ctx, api_key)
    })
  }
  @llm.ModelSlot::ModelSlot(
    id="zai/" + config.model,
    label="Z.ai / " + config.model,
    provider_id="zai",
    model_id=config.model,
    port~,
    api_key=Some(api_key),
    thinking_efforts=slot_efforts,
    default_effort~,
    rebuild_on_api_key=Some(fn(credential) {
      let rebuilt = ZaiConfig::for_model(
        credential.secret,
        config.model,
        base_url=config.base_url,
        endpoint_prefix=config.endpoint_prefix,
      ) catch {
        err => abort("zai catalog api-key rebuild failed: " + err.to_string())
      }
      let with_effort = if config.reasoning_effort == "" {
        rebuilt
      } else {
        rebuilt.with_reasoning_effort(config.reasoning_effort) catch {
          err => abort("zai catalog api-key rebuild failed: " + err.to_string())
        }
      }
      zai_catalog_slot(with_effort, ctx, api_key)
    }),
    rebuild_on_effort~,
  )
}

///|
/// Static catalog: one slot per GLM model the plan serves. `preferred_id`
/// (the configured model) is ordered first.
pub fn ZaiModelPort::model_catalog(
  self : ZaiModelPort,
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  let api_key_impl = ZaiProvider(ctx=self.ctx)
  let api_key : &@llm.ApiKeyFactory = api_key_impl
  let slots : Array[@llm.ModelSlot] = []
  for info in zai_models() {
    if info.id == self.config.model {
      slots.push(zai_catalog_slot(self.config, self.ctx, api_key))
    }
  }
  for info in zai_models() {
    if info.id != self.config.model {
      let config = ZaiConfig::for_model(
        self.config.api_key,
        info.id,
        base_url=self.config.base_url,
        endpoint_prefix=self.config.endpoint_prefix,
      )
      slots.push(zai_catalog_slot(config, self.ctx, api_key))
    }
  }
  @llm.ProviderModelCatalog::ProviderModelCatalog(provider_id="zai", slots~, capabilities=[
    "chat", "streaming", "api_key", "coding_plan",
  ])
}
