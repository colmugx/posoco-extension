///|
// ============================================================================
// fallback.mbt — ToolProvider for unsupported targets (wasm, wasm-gc).
//
// Active on: #cfg(not(any(target="native", target="js")))
//
// Content search requires a file-walking API (@fs.walk on native, rg on js).
// Neither exists on wasm/wasm-gc. Rather than omit the tool entirely
// (which would make GrepTools::GrepTools() fail to compile due to missing
// trait impl), we provide a complete but inert impl: list_tools returns [],
// execute raises immediately.
// ============================================================================

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for GrepTools with fn list_tools(
  _self : GrepTools,
) -> Array[@posoco.ToolDef] {
  []
}

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for GrepTools with fn execute(
  _self : GrepTools,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "content search requires native or js target (got wasm/wasm-gc)",
  )
}
