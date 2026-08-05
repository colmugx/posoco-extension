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
/// Canonical constructor. Use this everywhere to avoid cross-target naming drift.
pub fn ReadTools::ReadTools() -> ReadTools {
  ReadTools::{  }
}

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

///|
/// Shared `read` execute logic. Target-agnostic; only the IO adaptor differs.
/// Each target's execute constructs its own adaptor and delegates here — the
/// one place to test the business rules.
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
