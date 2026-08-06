///|
/// ShellTools — shell command execution tool provider.
///
/// On native, executes via `@process.collect_output_merged("sh", ...)`.
/// On js (bun), executes via `Bun.spawn`. On wasm/wasm-gc, the tool is not
/// listed and execute raises `RuntimeError::InvocationFailed`.
pub(all) struct ShellTools {
  // Stateless — all configuration comes from ToolCall arguments at execute time.
}

///|
/// Canonical constructor. Use this everywhere.
pub fn ShellTools::ShellTools() -> ShellTools {
  ShellTools::{  }
}

// ToolProvider is split into two complete #cfg partitions (native/js real, others inert); shared_list_tools avoids duplicating the ToolDef construction.

///|
/// Shared tool list (bash only). Both native and js ShellTools expose the
/// same single tool definition; only `execute` differs per target.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  // OpenAI/DeepSeek tool schema requires `parameters` to be a JSON Schema with
  // `type: "object"`; strict servers otherwise reject with HTTP 400
  // (`invalid_union_discriminator`). See posoco-ext-read/write/edit for the
  // canonical pattern.
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
      name: @posoco.ToolName::unchecked("bash"),
      description: "Execute a shell command and return its output",
      input_schema: cmd_schema,
      owner: @posoco.OwnerId::unchecked("posoco_ext_bash"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_bash"),
    },
  ]
}

///|
/// Extract command string from ToolCall arguments JSON.
/// A missing or non-String cmd/command is a typed error, not a silent fallback
/// that runs the entire JSON blob as a shell command.
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

///|
/// Native decode failure — non-UTF-8 output must not masquerade as success.
fn bash_decode_failure(exit_code : Int) -> String {
  "bash: decode failed (stage=decode_output, category=invalid_utf8, exit_code=\{exit_code})"
}

///|
/// Native collect_output failure.
fn bash_collect_output_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "bash: process failed (stage=collect_output)",
  )
}
