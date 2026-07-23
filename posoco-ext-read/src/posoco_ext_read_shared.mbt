///|
/// posoco_ext_read_shared.mbt — target-agnostic helpers shared by native + js.
///
/// Lives in [native, js] target set. Must NOT import target-specific deps.

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
/// Shared tool definition for the `read` tool.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: "read",
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
      metadata: None,
      source: Some("posoco_ext_read"),
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
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let path = extract_path(call.arguments)
  // exists() returns false for a missing file (recoverable → message);
  // it raises RuntimeError only on a genuine IO error (permission, etc).
  if !io.exists(path) {
    return @posoco.ToolResult::{
      content: "File not found: \{@devkit.sanitize_path(path)}",
      structured: None,
      is_error: true,
    }
  }
  let content = io.read_text(path)
  @posoco.ToolResult::{ content, structured: None, is_error: false }
}
