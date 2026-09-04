// Inert ToolProvider for targets without a process-spawn API (wasm/wasm-gc):
// list_tools returns [], execute raises immediately. Omitting the impl would
// make AstGrepTools::AstGrepTools() fail to compile for a missing trait impl.

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for AstGrepTools with fn list_tools(
  _self : AstGrepTools,
) -> Array[@posoco.ToolDef] {
  []
}

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for AstGrepTools with fn execute(
  _self : AstGrepTools,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "structural search requires native or js target (got wasm/wasm-gc)",
  )
}
