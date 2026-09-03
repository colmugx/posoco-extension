///|
// Vault access needs a subprocess API (@process on native, Bun.spawn on js),
// which wasm/wasm-gc lacks. A missing impl would fail to compile, so this
// file supplies complete but inert impls: no tools, no commands, lifecycle
// probes no-op. (on_compose lives in hook_prompt.mbt for all targets.)
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for ObsidianTools with fn list_tools(
  _self : ObsidianTools,
) -> Array[@posoco.ToolDef] {
  []
}

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.ToolProvider for ObsidianTools with fn execute(
  _self : ObsidianTools,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "Obsidian vault access requires native or js target (got wasm/wasm-gc)",
  )
}

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.Lifecycle for ObsidianTools with fn on_start(
  _self : ObsidianTools,
) -> Unit {
  // No subprocess API to probe.
}

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.Lifecycle for ObsidianTools with fn on_shutdown(
  _self : ObsidianTools,
) -> Unit {

}

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.CommandPort for ObsidianTools with fn commands(
  _self : ObsidianTools,
) -> Array[@posoco.CommandDef] {
  []
}

///|
#cfg(not(any(target="native", target="js")))
pub impl @posoco.CommandPort for ObsidianTools with fn invoke(
  _self : ObsidianTools,
  id : String,
  _args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  @posoco.CommandOutcome::Failure(
    reason="Obsidian commands require native or js target (got wasm/wasm-gc): \{id}",
  )
}
