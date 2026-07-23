///|
/// posoco_ext_bash_shared.mbt — target-agnostic helpers shared by native + js.
///
/// Lives in [native, js] target set. Must NOT import target-specific deps
/// (no @process on native, no extern "js" here). Just pure JSON parsing +
/// ToolDef construction that both backends need.

///|
/// Shared tool list (bash + shell alias). Both native and js ShellTools
/// expose the same two tool definitions; only `execute` differs per target.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  // OpenAI/DeepSeek tool schema requires `parameters` to be a JSON Schema with
  // `type: "object"`. Previously this sent `{"cmd": "..."}` (a string value,
  // not a nested schema), which strict servers reject with HTTP 400
  // (`invalid_union_discriminator`, expected `type: "object"`). See
  // posoco-ext-read/write/edit for the canonical pattern.
  let cmd_schema : Json = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            (
              "cmd",
              Json::object(
                Map::from_array([
                  ("type", Json::string("string")),
                  ("description", Json::string("The shell command to execute")),
                ]),
              ),
            ),
          ]),
        ),
      ),
      ("required", Json::array([Json::string("cmd")])),
    ]),
  )
  [
    @posoco.ToolDef::{
      name: "bash",
      description: "Execute a shell command and return its output",
      input_schema: cmd_schema,
      metadata: None,
      source: Some("posoco_ext_bash"),
    },
    @posoco.ToolDef::{
      name: "shell",
      description: "Execute a shell command (alias for bash)",
      input_schema: cmd_schema,
      metadata: None,
      source: Some("posoco_ext_bash"),
    },
  ]
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

///|
/// Shared empty-command error (used by both native + js execute paths).
fn bash_empty_command_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "bash: invocation failed (stage=arguments, category=empty_command)",
  )
}
