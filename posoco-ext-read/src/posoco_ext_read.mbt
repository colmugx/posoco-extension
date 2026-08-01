///|
// ============================================================================
// posoco-ext-read — file reading tool.
//
// File organization:
//   posoco_ext_read.mbt          — all targets: struct, ctor, shared helpers,
//                                  FsIo trait, SystemPromptContributor,
//                                  execute_read_impl, list_tools schema
//   posoco_ext_read_native.mbt   — #cfg(target="native"): NativeFsIo adaptor
//                                  + complete ToolProvider impl (via @fs)
//   posoco_ext_read_js.mbt       — #cfg(target="js"):      JsFsIo adaptor
//                                  + complete ToolProvider impl (via Bun.file)
//   fallback.mbt                 — #cfg(not(any(native,js))): empty list + error
//
// The struct + FsIo trait + shared business logic live HERE so every target
// sees the same type. Only the IO adaptor + ToolProvider impl differ per
// platform; each platform's adaptor file provides those via #cfg partitions.
// ============================================================================

///|
/// ReadTools — file reading tool provider.
///
/// On native, reads via `@fs.read_file`. On js (bun), reads via `Bun.file`.
/// On wasm/wasm-gc, the tool is not listed and execute raises
/// `RuntimeError::InvocationFailed`.
pub(all) struct ReadTools {
  // Stateless — all configuration comes from ToolCall arguments at execute time.
}

///|
/// Canonical constructor. Use this everywhere — the old `ReadTools()` positional
/// form is removed to avoid cross-target naming drift.
pub fn ReadTools::ReadTools() -> ReadTools {
  ReadTools::{  }
}

// ---------------------------------------------------------------------------
// SystemPromptContributor — identical on every target.
// ---------------------------------------------------------------------------

///|
pub impl @posoco.SystemPromptContributor for ReadTools with fn system_prompt(
  _self : ReadTools,
) -> String {
  "Use read to inspect exact file contents before changing them."
}

// ---------------------------------------------------------------------------
// FsIo trait — the IO adaptor seam. Native and js each provide an impl.
// ---------------------------------------------------------------------------

///|
/// File-system IO boundary for the `read` tool.
///
/// `@fs` is native-only, so each target supplies its own adaptor. The shared
/// `execute_read_impl` below talks only to this trait, keeping the business
/// rules (missing-file message, error staging, result shape) in one place.
priv trait FsIo {
  /// Does the file exist? `false` = missing (recoverable); raise = IO error.
  async fn exists(self : Self, path : String) -> Bool raise @posoco.RuntimeError

  /// Read the entire file as a UTF-8 string. Raise on IO or decode failure.
  async fn read_text(self : Self, path : String) -> String raise @posoco.RuntimeError
}

// ---------------------------------------------------------------------------
// Shared tool definition + argument extraction + failure formatting.
// ---------------------------------------------------------------------------

///|
/// Shared tool list for the `read` tool. Both native and js ReadTools expose
/// the same tool definition; only the IO adaptor differs per target.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("read"),
      description: "Read a file's contents. Returns the text content of the file at the given path.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Path to the file to read"),
          }),
        }),
        "required": Json::array([Json::string("path")]),
      }),
      owner: @posoco.OwnerId::unchecked("posoco_ext_read"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_read"),
    },
  ]
}

///|
/// Extract `path` from ToolCall arguments. Typed error on missing/non-string.
fn extract_path(args : Json) -> String raise @posoco.RuntimeError {
  match args {
    Object(obj) =>
      match obj.get("path") {
        Some(String(p)) => p
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "read: 'path' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool(
            "read: missing 'path' argument",
          )
      }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "read: arguments must be a JSON object",
      )
  }
}

///|
/// Format a `read` failure RuntimeError with sanitized path.
fn read_failure(stage : String, path : String) -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "read: \{stage} failed for '\{@devkit.sanitize_path(path)}'",
  )
}

// ---------------------------------------------------------------------------
// execute_read_impl — single source of truth for the read tool's logic.
// Each target's ReadTools::execute constructs its own FsIo adaptor and
// delegates here. This is the one place to test the business rules.
// ---------------------------------------------------------------------------

///|
/// Shared `read` execute logic. Target-agnostic; only the IO adaptor differs.
async fn execute_read_impl(
  io : &FsIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let path = extract_path(call.arguments)
  // exists() returns false for a missing file (recoverable → message);
  // it raises RuntimeError only on a genuine IO error (permission, etc).
  if !io.exists(path) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="File not found: \{@devkit.sanitize_path(path)}",
      structured=None,
    )
  }
  let content = io.read_text(path)
  @posoco.ToolOutcome::Success(content~, structured=None)
}
