///|
// ============================================================================
// fallback.mbt — ToolProvider for unsupported targets (wasm, wasm-gc).
//
// Active on: #cfg(not(any(target="native", target="js")))
//
// Glob scanning requires a filesystem walk API (@fs.walk on native, Bun.Glob
// on js). Neither exists on wasm/wasm-gc. Rather than omit the tool entirely
// (which would make GlobTools::new() fail to compile due to missing trait
// impl), we provide a complete but inert impl: list_tools returns [] (no tools
// advertised to the model), execute raises immediately.
// ============================================================================

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for GlobTools with fn list_tools(
  _self : GlobTools,
) -> Array[@posoco.ToolDef] {
  []
}

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for GlobTools with fn execute(
  _self : GlobTools,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "glob scanning requires native or js target (got wasm/wasm-gc)",
  )
}
