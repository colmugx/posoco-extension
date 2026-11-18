///|
pub(all) struct ShellTools {
  names : Array[String]
}

///|
pub fn default_shell_tools() -> ShellTools {
  ShellTools::{ names: ["bash", "sh", "zsh", "shell", "cmd", "powershell"], }
}

///|
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
  @posoco.ExtensionManifest(id="posoco_ext_rtk", hooks=[self])
}

///|
pub extend RTKHook with @posoco.Extension::{extension_id, manifest}

///|
/// Rewrite shell calls in place. A deferred shell call reaches this hook as
/// its own child call — the gateway re-enters the kernel child pipeline under
/// the real tool's name — so the gate classifies and rewrites exactly what the
/// kernel will dispatch, with no envelope to unwrap or rebuild.

///|
/// Rewrite seam: resolve `rtk rewrite <cmd>` to its rewritten shell command
/// (`None` = no rewrite). Backends implement only this; classification and
/// ToolCall rewriting stay in the shared impl, so tests script the seam
/// instead of spawning the real rtk binary.
priv trait RTKRewrite {
  async fn rewrite(self : Self, rtk_path : String, cmd : String) -> String?
}

///|
/// Shared decision body. `rewriter` is the backend seam (tests script it).
async fn before_tool_impl(
  rewriter : &RTKRewrite,
  self : RTKHook,
  call : @posoco.ToolCall,
) -> @posoco.ToolDecision {
  // A deferred shell call arrives here as its own child call, so the name and
  // arguments judged below are already the real tool's.
  let name = call.name.to_string()
  if !self.shell_tools.names.contains(name) {
    return Approve(call~)
  }
  let cmd = extract_command(call.arguments) catch {
    error => return Reject(reason=error.to_string())
  }
  match rewriter.rewrite(self.rtk_path, cmd) {
    Some(rewritten) if rewritten != cmd =>
      Approve(call=rewrite_tool_call(call, rewritten))
    _ => Approve(call~)
  }
}

///|
/// Production dispatch: the backend's real spawn-backed rewriter.
impl @posoco.PipelineHook for RTKHook with fn before_tool(
  self : RTKHook,
  call : @posoco.ToolCall,
) -> @posoco.ToolDecision {
  before_tool_impl(rtk_default_rewriter(), self, call)
}

///|
pub extend RTKHook with @posoco.PipelineHook::{
  on_post_event,
  on_turn_begin,
  before_model,
  on_turn_end,
}
