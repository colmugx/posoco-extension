// Inert ToolProvider for wasm/wasm-gc, where moonbitlang/async has no HTTP
// stack. Pinned to [wasm, wasm-gc] in moon.pkg so exactly one ToolProvider
// impl compiles per target (posoco_ext_webfetch.mbt covers native+js):
// list_tools returns [], execute raises immediately.

///|
pub impl @posoco.ToolProvider for WebFetchTools with fn list_tools(
  _self : WebFetchTools,
) -> Array[@posoco.ToolDef] {
  []
}

///|
pub impl @posoco.ToolProvider for WebFetchTools with fn execute(
  _self : WebFetchTools,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "webfetch: not available on this backend",
  )
}
