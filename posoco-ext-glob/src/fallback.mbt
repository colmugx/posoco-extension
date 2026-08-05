///|
// Glob scanning needs a filesystem walk API (@fs.walk on native, Bun.Glob on
// js), which wasm/wasm-gc lacks. A missing ToolProvider impl would fail to
// compile, so this file supplies a complete but inert one: list_tools returns
// [] and execute raises immediately.
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
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "glob scanning requires native or js target (got wasm/wasm-gc)",
  )
}
