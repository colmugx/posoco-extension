///|
// ============================================================================
// posoco-ext-bash — shell command execution tool.
//
// File organization:
//   posoco_ext_bash.mbt          — all targets: struct, ctor, shared helpers,
//                                  SystemPromptContributor, list_tools
//   posoco_ext_bash_native.mbt   — #cfg(target="native"): execute via @process
//   posoco_ext_bash_js.mbt       — #cfg(target="js"):      execute via Bun.spawn
//   fallback.mbt                 — #cfg(not(any(native,js))): empty list + error
//
// The struct + list_tools + SystemPromptContributor live HERE so every target
// sees the same type. Only `execute` differs per platform; each platform's
// adaptor file provides just that one method via a separate trait impl block.
// ============================================================================

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
/// Canonical constructor. Use this everywhere — the old `ShellTools()` positional
/// form is removed to avoid cross-target naming drift.
pub fn ShellTools::ShellTools() -> ShellTools {
  ShellTools::{  }
}

// ---------------------------------------------------------------------------
// SystemPromptContributor — identical on every target.
// ---------------------------------------------------------------------------

///|
pub impl @posoco.SystemPromptContributor for ShellTools with fn system_prompt(
  _self : ShellTools,
) -> String {
  "Use bash for focused inspection and verification commands. Report command failures; never claim an unchecked result."
}

// ---------------------------------------------------------------------------
// ToolProvider — split into two #cfg partitions:
//
//   #cfg(any(target="native", target="js"))   → real list_tools + execute
//   #cfg(not(any(target="native", target="js"))) → empty list_tools + error execute
//
// Each partition is a COMPLETE impl block (both methods). The shared_list_tools
// helper below avoids duplicating the ToolDef construction across partitions.
// ---------------------------------------------------------------------------

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
      name: @posoco.ToolName::unchecked("bash"),
      description: "Execute a shell command and return its output",
      input_schema: cmd_schema,
      owner: @posoco.OwnerId::unchecked("posoco_ext_bash"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_bash"),
    },
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("shell"),
      description: "Execute a shell command (alias for bash)",
      input_schema: cmd_schema,
      owner: @posoco.OwnerId::unchecked("posoco_ext_bash"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_bash"),
    },
  ]
}

// ---------------------------------------------------------------------------
// Shared helpers — pure functions used by all execute impls.
// ---------------------------------------------------------------------------

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
