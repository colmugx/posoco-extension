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
/// On native, executes via `@process.collect_output_merged`. On js (bun),
/// executes via `Bun.spawn`. On wasm/wasm-gc, the tool is not listed and
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
  PowerShellTools::{ exe: resolve_exe(exe), anchor }
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
                  (
                    "description",
                    Json::string("The PowerShell command to execute"),
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
    "PowerShell 7+ syntax: `&&` and `||` pipeline chains are supported."
  } else {
    "Windows PowerShell 5.1 syntax: `&&` and `||` are NOT supported; chain statements with `;` or `if ($?)`."
  }
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("powershell"),
      description: "Run a PowerShell command via \{exe} (-NoProfile -NonInteractive). \{chaining} Read environment variables with $env:NAME. Each call runs in a fresh PowerShell session in the workspace root; `cd` does not persist between calls. Use paths relative to the workspace root.",
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
              "powershell: 'cmd' argument must be a string",
            )
        }
      } else if map.contains("command") {
        match map["command"] {
          Json::String(s) => s
          _ =>
            raise @posoco.RuntimeError::UnknownTool(
              "powershell: 'command' argument must be a string",
            )
        }
      } else {
        raise @posoco.RuntimeError::UnknownTool(
          "powershell: missing 'cmd' or 'command' argument",
        )
      }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "powershell: arguments must be a JSON object with a 'cmd' field",
      )
  }
}

///|
/// Shared empty-command error (used by both native + js execute paths).
fn ps1_empty_command_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "powershell: invocation failed (stage=arguments, category=empty_command)",
  )
}

///|
/// Native decode failure — non-UTF-8 output must not masquerade as success.
fn ps1_decode_failure(exit_code : Int) -> String {
  "powershell: decode failed (stage=decode_output, category=invalid_utf8, exit_code=\{exit_code})"
}

///|
/// Native collect_output failure.
fn ps1_collect_output_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "powershell: process failed (stage=collect_output)",
  )
}

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
