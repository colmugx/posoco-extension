///|
// PowerShell execution needs a subprocess API (@process on native, Bun.spawn
// on js); neither exists on wasm/wasm-gc. Rather than omit the tool entirely
// (which would break compilation for the missing trait impl), provide a
// complete but inert impl: list_tools returns [] and execute raises
// immediately. Platform probes report non-Windows so no guidance is emitted.
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for PowerShellTools with fn list_tools(
  _self : PowerShellTools,
) -> Array[@posoco.ToolDef] {
  []
}

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for PowerShellTools with fn execute(
  _self : PowerShellTools,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "powershell execution requires native or js target (got wasm/wasm-gc)",
  )
}

///|
#cfg(not(any(target="native", target="js")))
fn ps1_platform_is_windows() -> Bool {
  false
}

///|
#cfg(not(any(target="native", target="js")))
fn ps1_platform_detail() -> String {
  ""
}

///|
#cfg(not(any(target="native", target="js")))
fn resolve_exe(exe : String) -> String {
  exe
}
