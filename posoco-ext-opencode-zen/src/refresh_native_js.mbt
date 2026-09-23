///|
/// RefreshableProviderFactory::refresh impl via @http.
///
/// Compiled on native, wasm, and js: `fetch_zen_models` drives
/// moonbitlang/async/http, which is unavailable on wasm-gc.

///|
/// Live catalog refresh. Performs one authenticated `/models` request against
/// the Zen gateway and builds a multi-slot catalog from the response, pinning
/// the configured model first. Transport, schema, or HTTP failures on the Zen
/// listing abort composition — this path never falls back to the static
/// single-model catalog, matching the DeepSeek refresh contract. The
/// models.dev surfaces request is the one deliberate exception: it only
/// enriches the effort picker, so any failure degrades to an empty map (every
/// model then presents the off/on fallback) and never aborts composition.
#cfg(any(target="native", target="wasm", target="js"))
pub impl @llm.RefreshableProviderFactory for OpenCodeZenProvider with fn refresh(
  self : OpenCodeZenProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let api_key = match zen_resolve_api_key(source) {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let base_url = zen_resolve_base_url(source)
  let preferred = zen_resolve_model(source)
  let config = OpenCodeZenConfig(api_key, base_url~, model=preferred)
  let models = fetch_zen_models(config.base_url, config.api_key) catch {
    err =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_opencode_zen",
        detail="OpenCode Zen model catalog refresh failed: " + err.to_string(),
      )
  }
  // Deliberate degradation: a missing models.dev mirror must not fail the
  // whole refresh — the picker falls back to off/on per model.
  let surfaces : Map[String, ZenReasoningSurface] = fetch_models_dev_surfaces() catch {
    _ => Map::from_array([])
  }
  let api_key_factory : &@llm.ApiKeyFactory = self
  let catalog = zen_model_catalog(
    config, models, preferred, surfaces, api_key_factory,
  )
  @llm.ProviderBuildResult::Ready(catalog)
}
