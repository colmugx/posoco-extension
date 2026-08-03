///|
// Shell execution needs a subprocess API (@process on native, Bun.spawn on js);
// neither exists on wasm/wasm-gc. Rather than omit the tool entirely (which
// would break compilation for the missing trait impl), provide a complete but
// inert impl: list_tools returns [] and execute raises immediately.
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
