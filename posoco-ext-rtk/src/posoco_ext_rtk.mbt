///|
pub(all) struct ShellTools {
  names : Array[String]
}

///|
/// Default shell tools — used when no custom list is provided.
pub fn default_shell_tools() -> ShellTools {
  ShellTools::{ names: ["bash", "sh", "zsh", "shell", "cmd", "powershell"] }
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
  rewrite : (String) -> String?
}

///|
pub fn RTKHook::RTKHook(
  rtk_path : String,
  rewrite : (String) -> String?,
) -> RTKHook {
  RTKHook::{ rtk_path, shell_tools: default_shell_tools(), rewrite }
}

///|
pub fn RTKHook::with_shell_tools(
  rtk_path : String,
  shell_tools : ShellTools,
  rewrite : (String) -> String?,
) -> RTKHook {
  RTKHook::{ rtk_path, shell_tools, rewrite }
}

///|
pub fn default_rtk_rewrite(_rtk_path : String, _cmd : String) -> String? {
  None
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
/// Rewrites shell-tool calls; every other tool is approved unchanged.
/// Malformed shell arguments surface as `Reject`; a successful rewrite
/// returns `Approve(call~)` with the rewritten call.
pub impl @posoco.Extension for RTKHook with fn extension_id(_self : RTKHook) -> String {
  "posoco_ext_rtk"
}

///|
pub impl @posoco.Extension for RTKHook with fn manifest(self : RTKHook) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::empty(id="posoco_ext_rtk")
  { ..manifest, hooks: [self] }
}

///|
pub extend RTKHook with @posoco.Extension::{extension_id, manifest}

///|
pub impl @posoco.PipelineHook for RTKHook with fn before_tool(
  self : RTKHook,
  call : @posoco.ToolCall,
) -> @posoco.ToolDecision {
  if !is_shell_tool(call.name, self.shell_tools) {
    return Approve(call~)
  }
  let extracted : Result[String, @posoco.RuntimeError] = Ok(
    extract_command(call.arguments),
  ) catch {
    error => Err(error)
  }
  match extracted {
    Err(error) =>
      // Malformed shell arguments: reject so the pump stops the run loudly.
      Reject(reason=error.to_string())
    Ok(cmd) =>
      match (self.rewrite)(cmd) {
        Some(rewritten) if rewritten != cmd => {
          let new_call = rewrite_tool_call(call, rewritten)
          Approve(call=new_call)
        }
        // Pass through: no rewrite, or rewrite identical to original.
        _ => Approve(call~)
      }
  }
}
