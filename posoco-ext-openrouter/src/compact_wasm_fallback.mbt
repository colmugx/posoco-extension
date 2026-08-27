///|
/// compact_wasm_fallback.mbt — ModelPort::compact impl for wasm/wasm-gc.
///
/// `@http` is unavailable on wasm, so the summarize call is impossible. This
/// fallback supplies a complete `ModelPort::compact` impl that raises
/// immediately, keeping the trait fully satisfied on every backend so the
/// package exports a real mbti.

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
