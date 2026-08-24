///|
/// refresh_native_js.mbt — RefreshableProviderFactory::refresh impl via @http.
///
/// Compiled on native and js only: `fetch_openrouter_models` drives
/// moonbitlang/async/http, unavailable on wasm/wasm-gc. The trait's
/// `provider_id` impl lives in provider_factory.mbt (all backends); this
/// file owns only the live catalog refresh. On wasm, a fallback impl in
/// refresh_wasm_fallback.mbt satisfies the trait so the package exports a
/// complete mbti.

///|
/// Live catalog refresh: one authenticated `GET /models` request, a multi-slot
/// catalog from the response, the settings-pinned model first. Transport,
/// schema, or HTTP failures abort as typed composition errors — this path
/// never falls back to the static single-model catalog, matching the
/// DeepSeek/Zen refresh contract.
pub impl @llm.RefreshableProviderFactory for OpenRouterProvider with fn refresh(
  self : OpenRouterProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let api_key = match openrouter_resolve_api_key(source) {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let base_url = openrouter_resolve_base_url(source)
  let preferred = match openrouter_resolve_setting_string(source, "model") {
    Some(value) => value
    None => ""
  }
  let http_referer = openrouter_resolve_setting_string(source, "http_referer")
  let title = openrouter_resolve_setting_string(source, "title")
  let models = fetch_openrouter_models(base_url, api_key) catch {
    err =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail="OpenRouter model catalog refresh failed: " + err.to_string(),
      )
  }
  let api_key_factory : &@llm.ApiKeyFactory = OpenRouterApiKeyFactory(
    ctx=self.ctx,
  )
  let catalog = openrouter_model_catalog(
    api_key,
    base_url,
    models,
    preferred,
    api_key_factory,
    http_referer~,
    title~,
  )
  @llm.ProviderBuildResult::Ready(catalog)
}
