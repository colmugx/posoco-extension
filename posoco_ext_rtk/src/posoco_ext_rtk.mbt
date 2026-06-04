///|
/// rtk_hook.mbt — RTKHook: a PipelineHook that rewrites shell commands
/// via the `rtk` subprocess to reduce LLM token consumption.
///
/// RTK (https://github.com/rtk-ai/rtk) is a CLI proxy that intercepts
/// shell commands and compresses their output. This hook forwards tool
/// calls containing shell commands through `rtk rewrite` before execution.
///
/// Graceful degradation: if the rtk binary is missing or rewrite fails,
/// the original command passes through unchanged.

///|

///|
/// A set of tool names that are considered "shell tools" — commands
/// whose argument string should be rewritten through RTK.
pub(all) struct ShellTools {
  names : Array[String]
}

///|
/// Default shell tools — used when no custom list is provided.
pub fn default_shell_tools() -> ShellTools {
  ShellTools::{ names: ["bash", "sh", "zsh", "shell", "cmd", "powershell"] }
}

///|
/// Check whether a tool name is a known shell tool.
pub fn is_shell_tool(name : String, tools : ShellTools) -> Bool {
  tools.names.contains(name)
}

///|
/// RTKHook — intercepts shell tool calls and optionally rewrites them.
///
/// The `rewrite` function takes a command string and returns an optional
/// rewritten command. Return `None` to pass through unchanged.
///
/// # Graceful Degradation
/// - `rewrite` returns `None` → original command passes through
/// - Binary missing or error → `rewrite` should return `None`
/// - Hook **never blocks** command execution
pub(all) struct RTKHook {
  rtk_path : String
  shell_tools : ShellTools
  rewrite : (String) -> String?
}

///|
/// Create a new RTKHook with a custom rewrite function.
/// The function receives a command string and should return `Some(rewritten)`
/// to rewrite it, or `None` to pass through unchanged.
pub fn RTKHook::new(
  rtk_path : String,
  rewrite : (String) -> String?,
) -> RTKHook {
  RTKHook::{ rtk_path, shell_tools: default_shell_tools(), rewrite }
}

///|
/// Create an RTKHook with a custom tool list and rewrite function.
pub fn RTKHook::with_shell_tools(
  rtk_path : String,
  shell_tools : ShellTools,
  rewrite : (String) -> String?,
) -> RTKHook {
  RTKHook::{ rtk_path, shell_tools, rewrite }
}

///|
/// Default rewrite implementation — always returns `None` (pass-through).
///
/// A production implementation requires platform-specific FFI
/// (e.g., `popen` on Unix) to call `{rtk_path} rewrite {cmd}`.
/// Users can provide their own rewrite function via `RTKHook::new`.
pub fn default_rtk_rewrite(_rtk_path : String, _cmd : String) -> String? {
  None
}

///|
/// Extract the command string from a ToolCall's arguments JSON.
/// Expects JSON of the form `{"cmd": "...", ...}` or `{"command": "..."}`.
/// Falls back to raw JSON string representation.
pub fn extract_command(args : Json) -> String {
  match args {
    Object(map) =>
      match map.get("cmd") {
        Some(String(s)) => s
        Some(_) => @debug.to_string(args)
        None =>
          match map.get("command") {
            Some(String(s)) => s
            Some(_) => @debug.to_string(args)
            None => @debug.to_string(args)
          }
      }
    _ => @debug.to_string(args)
  }
}

///|
/// Build a new ToolCall with rewritten arguments.
/// Preserves the original argument JSON shape when possible.
pub fn rewrite_tool_call(
  original : @posoco.ToolCall,
  rewritten_cmd : String,
) -> @posoco.ToolCall {
  let new_args = match original.arguments {
    Object(map) =>
      if map.contains("cmd") {
        let new_map = map
        new_map["cmd"] = Json::string(rewritten_cmd)
        Json::object(new_map)
      } else {
        Json::object(Map::from_array([("cmd", Json::string(rewritten_cmd))]))
      }
    _ => Json::object(Map::from_array([("cmd", Json::string(rewritten_cmd))]))
  }
  { id: original.id, name: original.name, arguments: new_args }
}

///|
pub impl @posoco.PipelineHook for RTKHook with fn on_stage(
  self,
  stage : @posoco.Stage,
) -> Result[@posoco.Stage, @posoco.HookError] {
  match stage {
    BeforeTool(call) if is_shell_tool(call.name, self.shell_tools) => {
      let cmd = extract_command(call.arguments)
      match (self.rewrite)(cmd) {
        Some(rewritten) if rewritten != cmd => {
          let new_call = rewrite_tool_call(call, rewritten)
          Ok(BeforeTool(new_call))
        }
        // Pass through: no rewrite, or rewrite identical to original
        _ => Ok(stage)
      }
    }
    // All other stages pass through unchanged
    _ => Ok(stage)
  }
}
