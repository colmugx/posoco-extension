///|
/// ShellTools — shell command execution tool provider.
///
/// When `anchor` is set, every command runs in a fresh shell with its
/// working directory pinned to the anchor root; when unset, the child
/// inherits the host process working directory (legacy behavior).
///
/// On native and wasm, executes via `@process.collect_output_merged("sh", ...)`.
/// On js (bun), executes via `Bun.spawn`. On wasm-gc, the tool is not
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

///|
/// Hard cap for model-visible shell output. This bounds transcript growth even
/// when a build/test command emits an unbounded log.
const BASH_OUTPUT_CHAR_CAP = 32_768

///|
/// Preserve a small prefix so command headers/context survive truncation;
/// spend the remaining budget on the tail where diagnostics usually land.
const BASH_OUTPUT_HEAD_CHARS = 4_096

///|
fn bash_char_count(text : String) -> Int {
  let mut count = 0
  for _ in text {
    count += 1
  }
  count
}

///|
fn bash_take_chars(text : String, limit : Int) -> String {
  let chars : Array[Char] = []
  let mut taken = 0
  for ch in text {
    if taken >= limit {
      break
    }
    chars.push(ch)
    taken += 1
  }
  String::from_array(chars)
}

///|
fn bash_tail_chars(text : String, total_chars : Int, limit : Int) -> String {
  if limit <= 0 {
    return ""
  }
  let skip = total_chars - limit
  let chars : Array[Char] = []
  let mut index = 0
  for ch in text {
    if index >= skip {
      chars.push(ch)
    }
    index += 1
  }
  String::from_array(chars)
}

///|
/// Normalize shell output for the model:
/// - successful short output is unchanged;
/// - non-zero exits expose the exit code once;
/// - long output is bounded to BASH_OUTPUT_CHAR_CAP with head+tail context.
fn bash_model_output(content : String, exit_code : Int) -> String {
  let raw = if exit_code == 0 {
    content
  } else if content == "" {
    "exit=\{exit_code}"
  } else {
    "exit=\{exit_code}\n\{content}"
  }
  let raw_chars = bash_char_count(raw)
  if raw_chars <= BASH_OUTPUT_CHAR_CAP {
    return raw
  }
  let marker = "\n…[cut]…\n"
  let tail_chars = BASH_OUTPUT_CHAR_CAP -
    BASH_OUTPUT_HEAD_CHARS -
    bash_char_count(marker)
  bash_take_chars(raw, BASH_OUTPUT_HEAD_CHARS) +
  marker +
  bash_tail_chars(raw, raw_chars, tail_chars)
}

// ToolProvider is split into two complete #cfg partitions (native/wasm/js real, wasm-gc inert); shared_list_tools avoids duplicating the ToolDef construction.

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
                  ("description", Json::string("Shell command")),
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
      description: "Run a shell command for builds, tests, git, or pipelines. Fresh shell at workspace root; `cd` does not persist.",
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
              "bash: 'cmd' must be a string",
            )
        }
      } else if map.contains("command") {
        match map["command"] {
          Json::String(s) => s
          _ =>
            raise @posoco.RuntimeError::UnknownTool(
              "bash: 'command' must be a string",
            )
        }
      } else {
        raise @posoco.RuntimeError::UnknownTool(
          "bash: missing 'cmd'",
        )
      }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "bash: arguments must be an object",
      )
  }
}

///|
/// Shared empty-command error (used by both native + js execute paths).
fn bash_empty_command_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "bash: empty cmd",
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
