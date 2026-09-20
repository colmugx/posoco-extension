///|
/// Provider-factory catalog builder that keeps prompt-cache policy and learned
/// compatibility state attached to every discovered model slot. The public
/// `openrouter_model_catalog` remains the provider-neutral/default-off helper
/// used by existing direct callers and tests.
fn openrouter_model_catalog_with_cache_policy(
  api_key : String,
  base_url : String,
  models : Array[OpenRouterModelInfo],
  preferred_id : String,
  api_key_factory : &@llm.ApiKeyFactory,
  prompt_cache_key_rejection_state : Ref[Bool],
  send_prompt_cache_key : Bool,
  http_referer? : String? = None,
  title? : String? = None,
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  if models.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_openrouter",
      detail="OpenRouter models endpoint returned an empty catalog",
    )
  }
  let slots : Array[@llm.ModelSlot] = []
  for info in openrouter_preferred_models(models, preferred_id) {
    let discovered = openrouter_config_for_info(
      api_key, base_url, info, http_referer, title,
    )
    let config = { ..discovered, send_prompt_cache_key, }
    slots.push(
      openrouter_catalog_slot(
        config, api_key_factory, prompt_cache_key_rejection_state,
      ),
    )
  }
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="openrouter",
    slots~,
    capabilities=["chat", "streaming", "reasoning", "api_key"],
  )
}
