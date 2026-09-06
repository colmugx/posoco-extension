///|
/// `@http` is unavailable on wasm, so a real chat request is impossible; this
/// impl raises immediately, keeping the trait satisfied and the package's
/// mbti real on every backend.

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ModelPort for OpenRouterModelPort with fn chat(
  _self : OpenRouterModelPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport(
    "openrouter chat requires native or js target (got wasm/wasm-gc)",
  )
}
