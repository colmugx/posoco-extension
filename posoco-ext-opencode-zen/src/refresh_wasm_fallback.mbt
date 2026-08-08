///|
/// refresh_wasm_fallback.mbt — RefreshableProviderFactory::refresh for wasm.
///
/// `@http` is unavailable on wasm, so the live `/models` fetch is impossible.
/// This fallback supplies a complete `refresh` impl that raises a typed
/// `CompositionError`, so the trait is fully satisfied on every backend and
/// the package exports a complete mbti. Pattern mirrors
/// posoco-ext-openai-compatible/src/chat_wasm_fallback.mbt.

///|
#cfg(not(any(target="native", target="js")))
pub impl @llm.RefreshableProviderFactory for OpenCodeZenProvider with fn refresh(
  _self : OpenCodeZenProvider,
  _source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  raise @posoco.CompositionError::ManifestSchemaError(
    manifest_id="posoco_ext_opencode_zen",
    detail="OpenCode Zen live model refresh requires native or js target (got wasm/wasm-gc)",
  )
}
