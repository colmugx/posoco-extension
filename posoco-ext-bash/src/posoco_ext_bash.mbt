///|
/// ShellTools — shell command execution tool provider.
///
/// When `anchor` is set, every command runs in a fresh shell with its
/// working directory pinned to the anchor root; when unset, the child
/// inherits the host process working directory (legacy behavior).
///
/// On native, executes via `@process.collect_output_merged("sh", ...)`.
/// On js (bun), executes via `Bun.spawn`. On wasm/wasm-gc, the tool is not
/// listed and execute raises `RuntimeError::InvocationFailed`.
pub(all) struct ShellTools {
  anchor : @devkit.WorkspaceAnchor?
}

///|
/// Canonical constructor. Use this everywhere.
pub fn ShellTools::ShellTools(
  anchor? : @devkit.WorkspaceAnchor? = None,
) -> ShellTools {
  ShellTools::{ anchor, }
}

// ToolProvider is split into two complete #cfg partitions (native/js real, others inert); shared_list_tools avoids duplicating the ToolDef construction.

///|
/// Shared tool list (bash only). Both native and js ShellTools expose the
/// same single tool definition; only `execute` differs per target.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  // OpenAI/DeepSeek tool schema requires `parameters` to be a JSON Schema with
  // `type: "object"`; strict servers otherwise reject with HTTP 400
  // (`invalid_union_discriminator`).
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
      description: "Run a shell command. Use only when the other tools cannot do the job — e.g. builds, tests, git, or multi-step pipelines. Each call runs in a fresh shell in the workspace root; `cd` does not persist between calls. Use paths relative to the workspace root. Read-only commands (ls, cat, grep, git status, find) are pre-approved by the permission policy and run without approval; all other commands may require user approval.",
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
/// Per-target import keepers: each backend compiles only one execute path,
/// so the other backend's import would trip `unused_package`. `@process`
/// backs the native runner, `@js_async` the bun runner.
#cfg(not(target="native"))
let _process_import_keeper : Unit = ignore(@process.unimplemented)

///|
#cfg(not(target="js"))
// The reference intentionally targets the native js_async stub, whose
// unimplemented alert is noise for a value that is never evaluated.
#warnings("-alert_unimplemented")
let _js_async_import_keeper : Unit = ignore(@js_async.AbortController::new)
