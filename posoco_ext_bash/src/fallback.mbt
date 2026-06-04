///|
/// fallback.mbt — wasm-gc/js fallback for posoco_ext_bash.
///
/// Shell execution requires native target (subprocess via @process).
/// On wasm-gc/js, tools are not listed and execute raises an error.

///|
/// ShellToolProvider — returns empty tool list on non-native targets.
pub(all) struct ShellToolProvider {}

///|
pub impl @posoco.ToolProvider for ShellToolProvider with fn list_tools(
  _self,
) -> Array[@posoco.ToolDef] {
  []
}

///|
/// ShellToolRuntime — raises error on non-native targets.
pub(all) struct ShellToolRuntime {}

///|
pub fn ShellToolRuntime::new() -> ShellToolRuntime {
  ShellToolRuntime::{  }
}

///|
pub impl @posoco.ToolRuntime for ShellToolRuntime with fn execute(
  _self,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "shell execution requires native target",
  )
}
