///|
// ============================================================================
// fallback.mbt — ToolProvider for unsupported targets (wasm, wasm-gc).
//
// Active on: #cfg(not(any(target="native", target="js")))
//
// File reading requires an IO API (@fs on native, Bun.file on js). Neither
// exists on wasm/wasm-gc. Rather than omit the tool entirely (which would
// make ReadTools::new() fail to compile due to missing trait impl), we
// provide a complete but inert impl: list_tools returns [] (no tools
// advertised to the model), execute raises immediately.
// ============================================================================

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for ReadTools with fn list_tools(
  _self : ReadTools,
) -> Array[@posoco.ToolDef] {
  []
}

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for ReadTools with fn execute(
  _self : ReadTools,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "file reading requires native or js target (got wasm/wasm-gc)",
  )
}
