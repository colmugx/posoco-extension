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
/// Check whether a tool name is a known shell tool.
pub fn is_shell_tool(name : String, tools : ShellTools) -> Bool {
  tools.names.contains(name)
}

///|
pub(all) struct RTKHook {
  rtk_path : String
  shell_tools : ShellTools
  rewrite : (String) -> String?
}

///|
pub fn RTKHook::new(
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
