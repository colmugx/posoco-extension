///|
/// Native+wasm+js: moonbitlang/async/http (`@http`) is unavailable on wasm-gc.

///|
/// Live catalog refresh: one authenticated `/models` request against the Go
/// gateway builds the multi-slot catalog (configured model pinned first),
/// enriched by the models.dev mirror for surfaces, windows, image input,
/// rates, and the SDK wire signal — best-effort: any mirror failure
/// degrades to the safe fallbacks and never aborts the refresh. The
/// `/usage` quota source re-registers with the current credential so the
/// pull consumers always read the live plane.
#cfg(any(target="native", target="wasm", target="js"))
pub impl @llm.RefreshableProviderFactory for OpenCodeGoProvider with fn refresh(
  self : OpenCodeGoProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let api_key = match go_resolve_api_key(source) {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let base_url = go_resolve_base_url(source)
  let preferred = go_resolve_model(source)
  let overrides = go_protocol_overrides(source)
  let policy = go_deepseek_policy(source)
  let config = @zen.OpenCodeZenConfig(
    api_key,
    base_url~,
    model=preferred,
    client_id="opencode-go",
    spend_source="posoco_ext_opencode_go",
  )
  let models = @zen.fetch_zen_models(config.base_url, config.api_key) catch {
    err =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_opencode_go",
        detail="OpenCode Go model catalog refresh failed: " + err.to_string(),
      )
  }
  // Deliberate degradation: a missing models.dev mirror must not fail the
  // whole refresh — the picker falls back to off/on per model, windows stay
  // undeclared, and the wire re-derives from the Go-plane table.
  let metas : Map[String, @zen.ZenModelMeta] = @zen.fetch_models_dev_meta() catch {
    _ => Map::from_array([])
  }
  let api_key_factory : &@llm.ApiKeyFactory = self
  let catalog = go_model_catalog(
    config,
    models,
    preferred,
    metas,
    api_key_factory,
    overrides~,
    policy=Some(policy),
    ctx=self.ctx,
  )
  go_register_quota_source(base_url, api_key)
  @llm.ProviderBuildResult::Ready(catalog)
}

///|
pub extend OpenCodeGoProvider with @posoco/ext-llm.RefreshableProviderFactory::{
  refresh,
}
