///|
// ============================================================================
// fallback.mbt — ToolProvider for unsupported targets (wasm, wasm-gc).
//
// Active on: #cfg(not(any(target="native", target="js")))
//
// File editing requires an IO API (@fs on native, Bun.file/Bun.write on js).
// Neither exists on wasm/wasm-gc. Rather than omit the tool entirely (which
// would make EditTools::new() fail to compile due to missing trait impl), we
// provide a complete but inert impl: list_tools returns [] (no tools
// advertised to the model), execute raises immediately.
// ============================================================================

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for EditTools with fn list_tools(
  _self : EditTools,
) -> Array[@posoco.ToolDef] {
  []
}

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for EditTools with fn execute(
  _self : EditTools,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "file editing requires native or js target (got wasm/wasm-gc)",
  )
}
