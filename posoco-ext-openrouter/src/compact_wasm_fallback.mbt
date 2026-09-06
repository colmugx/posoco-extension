///|
/// `@http` is unavailable on wasm, so the summarize call is impossible; this
/// impl raises immediately, keeping the trait satisfied and the package's
/// mbti real on every backend.

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ModelPort for OpenRouterModelPort with fn compact(
  _self : OpenRouterModelPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport(
    "openrouter compact requires native or js target (got wasm/wasm-gc)",
  )
}
