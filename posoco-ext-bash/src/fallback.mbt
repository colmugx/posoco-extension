///|
// ============================================================================
// fallback.mbt — ToolProvider for unsupported targets (wasm, wasm-gc).
//
// Active on: #cfg(not(any(target="native", target="js")))
//
// Shell execution requires a subprocess API (@process on native, Bun.spawn on
// js). Neither exists on wasm/wasm-gc. Rather than omit the tool entirely
// (which would make ShellTools::new() fail to compile due to missing trait
// impl), we provide a complete but inert impl: list_tools returns [] (no tools
// advertised to the model), execute raises immediately.
// ============================================================================

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for ShellTools with fn list_tools(
  _self : ShellTools,
) -> Array[@posoco.ToolDef] {
  []
}

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for ShellTools with fn execute(
  _self : ShellTools,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "shell execution requires native or js target (got wasm/wasm-gc)",
  )
}
