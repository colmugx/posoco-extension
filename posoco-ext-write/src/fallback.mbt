///|
// File writing requires an IO API (@fs on native+wasm, Bun.write on js); neither
// exists on wasm-gc. Provide a complete but inert impl so WriteTools
// compiles on every target: list_tools returns [] (no tools advertised to
// the model), execute raises immediately.
#cfg(not(any(target="native", target="wasm", target="js")))
pub impl @posoco.ToolProvider for WriteTools with fn list_tools(
  _self : WriteTools,
) -> Array[@posoco.ToolDef] {
  []
}

///|
#cfg(not(any(target="native", target="wasm", target="js")))
pub impl @posoco.ToolProvider for WriteTools with fn execute(
  _self : WriteTools,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "file writing requires native or js target (got wasm-gc)",
  )
}
