///|
/// posoco_ext_write_shared.mbt — target-agnostic helpers shared by native + js.

// ---------------------------------------------------------------------------
// FsIo trait — the IO adaptor seam. Native and js each provide an impl.
// ---------------------------------------------------------------------------

///|
/// File-system IO boundary for the `write` tool.
///
/// `@fs` is native-only, so each target supplies its own adaptor. The shared
/// `execute_write_impl` below talks only to this trait.
priv trait FsIo {
  /// Write text content to a file (create or truncate). Raise on IO failure.
  async fn write_text(self : Self, path : String, content : String) -> Unit raise @posoco.RuntimeError
}

// ---------------------------------------------------------------------------
// Shared tool definition + argument extraction + failure formatting.
// ---------------------------------------------------------------------------

///|
/// Shared tool definition for the `write` tool.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: "write",
      description: "Write text content to a file. Creates the file if it does not exist; truncates if it does.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Path to the file to write"),
          }),
          "content": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Text content to write"),
          }),
        }),
        "required": Json::array([Json::string("path"), Json::string("content")]),
      }),
      metadata: None,
      source: Some("posoco_ext_write"),
    },
  ]
}

///|
/// Extract `(path, content)` from ToolCall arguments.
fn extract_path_content(
  args : Json,
) -> (String, String) raise @posoco.RuntimeError {
  match args {
    Object(obj) => {
      let p = match obj.get("path") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "write: 'path' argument must be a string",
          )
        None => raise @posoco.RuntimeError::UnknownTool("write: missing 'path'")
      }
      let c = match obj.get("content") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "write: 'content' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("write: missing 'content'")
      }
      (p, c)
    }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "write: arguments must be a JSON object",
      )
  }
}

///|
/// Format a `write` failure RuntimeError with sanitized path.
fn write_failure(path : String) -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "write: write failed for '\{@devkit.sanitize_path(path)}'",
  )
}

// ---------------------------------------------------------------------------
// execute_write_impl — single source of truth for the write tool's logic.
// ---------------------------------------------------------------------------

///|
/// Shared `write` execute logic. Target-agnostic; only the IO adaptor differs.
async fn execute_write_impl(
  io : &FsIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let (path, content) = extract_path_content(call.arguments)
  io.write_text(path, content)
  @posoco.ToolResult::{
    content: "Wrote \{content.length()} bytes to \{path}",
    structured: None,
    is_error: false,
  }
}
