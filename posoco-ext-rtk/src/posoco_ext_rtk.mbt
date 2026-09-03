///|
pub(all) struct ShellTools {
  names : Array[String]
}

///|
/// Default shell tools — used when no custom list is provided.
pub fn default_shell_tools() -> ShellTools {
  ShellTools::{ names: ["bash", "sh", "zsh", "shell", "cmd", "powershell"], }
}

///|
/// Check whether a tool name is a known shell tool. Accepts the typed
/// `ToolName` wrapper.
pub fn is_shell_tool(name : @posoco.ToolName, tools : ShellTools) -> Bool {
  tools.names.contains(name.to_string())
}

///|
pub(all) struct RTKHook {
  rtk_path : String
  shell_tools : ShellTools
}

///|
pub fn RTKHook::RTKHook(rtk_path : String) -> RTKHook {
  RTKHook::{ rtk_path, shell_tools: default_shell_tools(), }
}

///|
pub fn RTKHook::with_shell_tools(
  rtk_path : String,
  shell_tools : ShellTools,
) -> RTKHook {
  RTKHook::{ rtk_path, shell_tools, }
}

///|
/// Extract the shell command from a tool call's arguments JSON.
///
/// Recognises `cmd` (preferred) and `command` (fallback) keys. Raises
/// `RuntimeError::UnknownTool` on malformed arguments so the pump surfaces
/// the failure as a tool business error.
pub fn extract_command(args : Json) -> String raise @posoco.RuntimeError {
  match args {
    Object(map) =>
      match map.get("cmd") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "rtk: shell argument 'cmd' must be a string",
          )
        None =>
          match map.get("command") {
            Some(String(s)) => s
            Some(_) =>
              raise @posoco.RuntimeError::UnknownTool(
                "rtk: shell argument 'command' must be a string",
              )
            None =>
              raise @posoco.RuntimeError::UnknownTool(
                "rtk: shell arguments require 'cmd' or 'command'",
              )
          }
      }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "rtk: shell arguments must be a JSON object",
      )
  }
}

///|
/// Build a rewritten `ToolCall` carrying `rewritten_cmd` in its `cmd` field.
/// Preserves all other argument keys.
pub fn rewrite_tool_call(
  original : @posoco.ToolCall,
  rewritten_cmd : String,
) -> @posoco.ToolCall {
  let new_map = match original.arguments {
    Object(map) => {
      let m = Map::from_array([("cmd", Json::string(rewritten_cmd))])
      for key in map.keys() {
        if key != "cmd" {
          m[key] = map[key]
        }
      }
      m
    }
    _ => Map::from_array([("cmd", Json::string(rewritten_cmd))])
  }
  {
    call_id: original.call_id,
    name: original.name,
    arguments: Json::object(new_map),
  }
}

///|
pub impl @posoco.Extension for RTKHook with fn extension_id(_self : RTKHook) -> String {
  "posoco_ext_rtk"
}

///|
pub impl @posoco.Extension for RTKHook with fn manifest(self : RTKHook) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::empty(id="posoco_ext_rtk")
  { ..manifest, hooks: [self], }
}

///|
pub extend RTKHook with @posoco.Extension::{extension_id, manifest}

///|
/// Rewrite shell calls, deferred or direct: a lazytools gateway `execute`
/// call names the real tool in `tool` and nests the shell arguments under
/// `arguments`. Unwrap to classify (inner name in the shell list), rewrite
/// the inner `cmd`, and hand the kernel back the shape it dispatched —
/// gateway calls are rewrapped, direct calls rewritten in place. Deferred
/// bash keeps rtk routing and per-scope approvals.
pub impl @posoco.PipelineHook for RTKHook with fn before_tool(
  self : RTKHook,
  call : @posoco.ToolCall,
) -> @posoco.ToolDecision {
  let is_gateway = call.name.to_string() == "tool_execute"
  let (name, effective) = @lazytools.LazyTools::unwrap_call(call)
  if !self.shell_tools.names.contains(name) {
    return Approve(call~)
  }
  let cmd = extract_command(effective.arguments) catch {
    error => return Reject(reason=error.to_string())
  }
  match rtk_rewrite(self.rtk_path, cmd) {
    Some(rewritten) if rewritten != cmd => {
      let inner = rewrite_tool_call(effective, rewritten)
      Approve(
        call=if is_gateway {
          @lazytools.LazyTools::rewrap_call(call, inner)
        } else {
          inner
        },
      )
    }
    _ => Approve(call~)
  }
}
