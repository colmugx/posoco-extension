///|
fn qwen_catalog_slot(
  config : QwenConfig,
  ctx : @devkit.ExtContext,
) -> @llm.ModelSlot {
  let provider = QwenProvider(ctx~)
  let api_key : &@llm.ApiKeyFactory = provider
  let port : &@posoco.ModelPort = QwenModelPort(config, ctx~)
  let efforts = qwen_slot_efforts(config)
  let default_effort = if efforts.is_empty() {
    None
  } else {
    Some(qwen_effort_label(config))
  }
  let rebuild_on_effort : ((String) -> @llm.ModelSlot)? = if efforts.is_empty() {
    None
  } else {
    Some(fn(effort) {
      let rebuilt = config.with_reasoning_effort(effort) catch {
        err => abort("qwen catalog effort rebuild failed: " + err.to_string())
      }
      qwen_catalog_slot(rebuilt, ctx)
    })
  }
  let capabilities : Array[String] = ["chat", "streaming", "api_key"]
  if config.supports_images {
    capabilities.push("image_in")
  }
  @llm.ModelSlot::ModelSlot(
    id="qwen/" + config.model,
    label="Qwen / " + config.model,
    provider_id="qwen",
    model_id=config.model,
    port~,
    api_key=Some(api_key),
    thinking_efforts=efforts,
    default_effort~,
    context_window=config.context_window,
    capabilities~,
    rebuild_on_api_key=Some(fn(credential) {
      let rebuilt = {
        ..config,
        api_key: credential.secret,
      }
      qwen_catalog_slot(rebuilt, ctx)
    }),
    rebuild_on_effort~,
  )
}

///|
pub fn QwenModelPort::model_catalog(
  self : QwenModelPort,
) -> @llm.ProviderModelCatalog {
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="qwen",
    slots=[qwen_catalog_slot(self.config, self.ctx)],
    capabilities=["chat", "streaming", "api_key"],
  )
}
