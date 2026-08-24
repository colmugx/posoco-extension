///|
/// refresh_wasm_fallback.mbt — RefreshableProviderFactory::refresh for wasm.
///
/// `@http` is unavailable on wasm, so the live `/models` fetch is impossible.
/// This fallback supplies a complete `refresh` impl that raises a typed
/// `CompositionError`, so the trait is fully satisfied on every backend and
/// the package exports a complete mbti. Pattern mirrors
/// posoco-ext-opencode-zen/src/refresh_wasm_fallback.mbt.

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
