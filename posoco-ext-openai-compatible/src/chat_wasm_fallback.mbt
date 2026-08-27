///|
/// chat_wasm_fallback.mbt — ModelPort::chat impl for wasm/wasm-gc.
///
/// `@http` is unavailable on wasm, so a real chat request is impossible. This
/// fallback supplies a complete `ModelPort::chat` impl that raises immediately
/// with a clear message, so:
///   - the trait is fully satisfied (compact + provider_config from the core
///     file + chat from here = all three methods), and
///   - the package exports a real mbti on every backend, unblocking downstream
///     packages (posoco-ext-llm, provider extensions) from resolving the type.
///
/// Pattern mirrors posoco-ext-read/src/fallback.mbt: a tool that needs a
/// platform capability supplies an inert impl on platforms that lack it.

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ModelPort for OpenAICompatibleModelPort with fn chat(
  _self : OpenAICompatibleModelPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport(
    "openai-compatible chat requires native or js target (got wasm/wasm-gc)",
  )
}
