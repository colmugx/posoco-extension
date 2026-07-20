///|
/// ShellTools — unified shell tool provider (list + execute).
/// Provides bash and shell command execution tools on native target.
pub(all) struct ShellTools {}

///|
pub fn ShellTools::new() -> ShellTools {
  ShellTools::{  }
}

///|
fn bash_collect_output_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "bash: process failed (stage=collect_output)",
  )
}

///|
fn bash_empty_command_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "bash: invocation failed (stage=arguments, category=empty_command)",
  )
}

///|
fn bash_decode_failure(exit_code : Int) -> String {
  "bash: decode failed (stage=decode_output, category=invalid_utf8, exit_code=" +
  exit_code.to_string() +
  ")"
}

///|
pub impl @posoco.ToolProvider for ShellTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  [
    @posoco.ToolDef::{
      name: "bash",
      description: "Execute a shell command and return its output",
      input_schema: Json::object(
        Map::from_array([("cmd", Json::string("the command to execute"))]),
      ),
      metadata: None,
      source: Some("posoco_ext_bash"),
    },
    @posoco.ToolDef::{
      name: "shell",
      description: "Execute a shell command (alias for bash)",
      input_schema: Json::object(
        Map::from_array([("cmd", Json::string("the command to execute"))]),
      ),
      metadata: None,
      source: Some("posoco_ext_bash"),
    },
  ]
}

///|
pub impl @posoco.ToolProvider for ShellTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let cmd = extract_command(call.arguments)
  if cmd == "" {
    raise bash_empty_command_failure()
  }
  let (exit_code, output_data) = @process.collect_output_merged("sh", [
    "-c", cmd,
  ]) catch {
    _ => raise bash_collect_output_failure()
  }
  // T07-B: decode failure must not masquerade as success. If the process
  // produced non-UTF-8 / undecodable output, surface it as a business-level
  // error (is_error=true) with a message that includes the exit code, so the
  // model can react instead of receiving a silent "(decoding error)" body
  // on an exit-0 success.
  let mut content = ""
  let mut decode_failed = false
  content = output_data.text() catch {
    _ => {
      decode_failed = true
      bash_decode_failure(exit_code)
    }
  }
  @posoco.ToolResult::{
    content,
    structured: None,
    is_error: exit_code != 0 || decode_failed,
  }
}

///|
/// Extract command string from ToolCall arguments JSON.
/// T07-B: a missing or non-String cmd/command is now a typed error, not a
/// silent fallback that runs the entire JSON blob as a shell command.
fn extract_command(args : Json) -> String raise @posoco.RuntimeError {
  match args {
    Json::Object(map) =>
      if map.contains("cmd") {
        match map["cmd"] {
          Json::String(s) => s
          _ =>
            raise @posoco.RuntimeError::UnknownTool(
              "bash: 'cmd' argument must be a string",
            )
        }
      } else if map.contains("command") {
        match map["command"] {
          Json::String(s) => s
          _ =>
            raise @posoco.RuntimeError::UnknownTool(
              "bash: 'command' argument must be a string",
            )
        }
      } else {
        raise @posoco.RuntimeError::UnknownTool(
          "bash: missing 'cmd' or 'command' argument",
        )
      }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "bash: arguments must be a JSON object with a 'cmd' field",
      )
  }
}
