///|
/// wasm has no `@http`, so the live `/models` fetch is impossible; refresh
/// raises a typed error instead.

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
