///|
/// fallback.mbt — wasm-gc/js fallback for posoco_ext_bash.
///
/// Shell execution requires native target (subprocess via @process).
/// On wasm-gc/js, tools are not listed and execute raises an error.

///|
/// ShellTools — returns empty tool list on non-native targets.
pub(all) struct ShellTools {}

///|
pub fn ShellTools::new() -> ShellTools {
  ShellTools::{  }
}

///|
pub impl @posoco.ToolProvider for ShellTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  []
}

///|
pub impl @posoco.ToolProvider for ShellTools with fn execute(
  _self,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "shell execution requires native target",
  )
}
