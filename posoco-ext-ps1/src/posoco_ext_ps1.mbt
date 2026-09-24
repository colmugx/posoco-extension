///|
/// PowerShellTools — PowerShell command execution tool provider plus a
/// system-prompt contributor with Windows-specific guidance.
///
/// `exe` defaults to "pwsh" (PowerShell 7+, cross-platform); on js (bun) the
/// constructor falls back to "powershell" when only Windows PowerShell 5.1 is
/// installed. When `anchor` is set, every command runs in a fresh PowerShell
/// session with its working directory pinned to the anchor root; when unset,
/// the child inherits the host process working directory.
///
/// On native and wasm, executes via `@process.collect_output_merged`.
/// On js (bun), executes via `Bun.spawn`. On wasm-gc, the tool is not listed and
/// execute raises `RuntimeError::InvocationFailed`.
pub(all) struct PowerShellTools {
  exe : String
  anchor : @devkit.WorkspaceAnchor?
}

///|
/// Canonical constructor. Use this everywhere.
pub fn PowerShellTools::PowerShellTools(
  exe? : String = "pwsh",
  anchor? : @devkit.WorkspaceAnchor? = None,
) -> PowerShellTools {
  PowerShellTools::{ exe: resolve_exe(exe), anchor, }
}

///|
const PS1_OUTPUT_CHAR_CAP = 32_768

///|
const PS1_OUTPUT_HEAD_CHARS = 4_096

///|
fn ps1_char_count(text : String) -> Int {
  let mut count = 0
  for _ in text {
    count += 1
  }
  count
}

///|
fn ps1_take_chars(text : String, limit : Int) -> String {
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
fn ps1_tail_chars(text : String, total_chars : Int, limit : Int) -> String {
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
/// Bound model-visible shell output while preserving command context and the
/// end-of-log diagnostics where PowerShell failures usually land.
fn ps1_model_output(content : String, exit_code : Int) -> String {
  let raw = if exit_code == 0 {
    content
  } else if content == "" {
    "exit=\{exit_code}"
  } else {
    "exit=\{exit_code}\n\{content}"
  }
  let raw_chars = ps1_char_count(raw)
  if raw_chars <= PS1_OUTPUT_CHAR_CAP {
    return raw
  }
  let marker = "\n…[cut]…\n"
  let tail_chars = PS1_OUTPUT_CHAR_CAP -
    PS1_OUTPUT_HEAD_CHARS -
    ps1_char_count(marker)
  ps1_take_chars(raw, PS1_OUTPUT_HEAD_CHARS) +
  marker +
  ps1_tail_chars(raw, raw_chars, tail_chars)
}

// ToolProvider is split into two complete #cfg partitions (native/js real,
// others inert); shared_list_tools avoids duplicating the ToolDef construction.

///|
/// Shared tool list (powershell only). The description adapts to the resolved
/// executable so the model knows which PowerShell flavor — and therefore which
/// chaining syntax — applies.
fn shared_list_tools(exe : String) -> Array[@posoco.ToolDef] {
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
                  (
                    "description",
                    Json::string("PowerShell command"),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
      ("required", Json::array([Json::string("cmd")])),
    ]),
  )
  let chaining = if exe.contains("pwsh") {
    "Supports &&/||."
  } else {
    "No &&/||; use ; or if ($?)."
  }
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("powershell"),
      description: "Run PowerShell via \{exe} on Windows. Use PowerShell syntax/cmdlets; fresh session at workspace root. \{chaining}",
      input_schema: cmd_schema,
      owner: @posoco.OwnerId::unchecked("posoco_ext_ps1"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_ps1"),
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
              "powershell: 'cmd' must be a string",
            )
        }
      } else if map.contains("command") {
        match map["command"] {
          Json::String(s) => s
          _ =>
            raise @posoco.RuntimeError::UnknownTool(
              "powershell: 'command' must be a string",
            )
        }
      } else {
        raise @posoco.RuntimeError::UnknownTool(
          "powershell: missing 'cmd'",
        )
      }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "powershell: arguments must be an object",
      )
  }
}

///|
/// Shared empty-command error (used by both native + js execute paths).
fn ps1_empty_command_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "powershell: empty cmd",
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

///|
/// True when the current process runs on Windows. Target-split internally:
/// js probes `process.platform`, native probes the `OS` environment variable.
pub fn is_windows() -> Bool {
  ps1_platform_is_windows()
}

///|
/// Best-effort platform detail string (e.g. "win32 10.0.26244"); empty when
/// unknown. Consumed by the system-prompt guidance.
pub fn detect_platform() -> String {
  ps1_platform_detail()
}
