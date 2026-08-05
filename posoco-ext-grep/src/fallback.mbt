// Inert ToolProvider for targets without a file-walking API (wasm/wasm-gc):
// list_tools returns [], execute raises immediately. Omitting the impl would
// make GrepTools::GrepTools() fail to compile for a missing trait impl.

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
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "content search requires native or js target (got wasm/wasm-gc)",
  )
}
