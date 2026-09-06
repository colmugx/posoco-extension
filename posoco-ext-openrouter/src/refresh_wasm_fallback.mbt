///|
/// `@http` is unavailable on wasm, so the live `/models` fetch is impossible;
/// this impl raises a typed `CompositionError`, keeping the trait satisfied
/// and the package's mbti real on every backend.

///|
#cfg(not(any(target="native", target="js")))
pub impl @llm.RefreshableProviderFactory for OpenRouterProvider with fn refresh(
  _self : OpenRouterProvider,
  _source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  raise @posoco.CompositionError::ManifestSchemaError(
    manifest_id="posoco_ext_openrouter",
    detail="OpenRouter live model refresh requires native or js target (got wasm/wasm-gc)",
  )
}
