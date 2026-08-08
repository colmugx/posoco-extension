///|
/// refresh_native_js.mbt — RefreshableProviderFactory::refresh impl via @http.
///
/// Compiled on native and js only: `fetch_zen_models` drives
/// moonbitlang/async/http, which is unavailable on wasm/wasm-gc. The
/// `provider_id` impl lives in the core provider_factory.mbt (all backends);
/// this file owns only the live catalog refresh. On wasm, a fallback impl in
/// refresh_wasm_fallback.mbt satisfies the trait so the package exports a
/// complete mbti.

///|
/// Live catalog refresh. Performs one authenticated `/models` request against
/// the Zen gateway and builds a multi-slot catalog from the response, pinning
/// the configured model first. Transport, schema, or HTTP failures abort
/// composition — this path never falls back to the static single-model
/// catalog, matching the DeepSeek refresh contract.
#cfg(any(target="native", target="js"))
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
  let config = @openai_compatible.OpenAICompatibleConfig::new(
    api_key,
    base_url~,
    model=preferred,
  )
  let models = fetch_zen_models(config.base_url, config.api_key) catch {
    err =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_opencode_zen",
        detail="OpenCode Zen model catalog refresh failed: " + err.to_string(),
      )
  }
  let api_key_factory : &@llm.ApiKeyFactory = self
  let catalog = zen_model_catalog(config, models, preferred, api_key_factory)
  @llm.ProviderBuildResult::Ready(catalog)
}
