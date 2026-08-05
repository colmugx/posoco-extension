///|
// File reading needs an IO API (@fs on native, Bun.file on js), which
// wasm/wasm-gc lacks. A missing ToolProvider impl would fail to compile, so
// this file supplies a complete but inert one: list_tools returns [] and
// execute raises immediately.
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
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "file reading requires native or js target (got wasm/wasm-gc)",
  )
}
