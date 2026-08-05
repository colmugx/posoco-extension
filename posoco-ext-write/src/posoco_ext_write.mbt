///|

///|
/// WriteTools — file writing tool provider.
///
/// On native, writes via `@fs.write_file`. On js (bun), writes via `Bun.write`.
/// On wasm/wasm-gc, the tool is not listed and execute raises
/// `RuntimeError::InvocationFailed`.
pub(all) struct WriteTools {
  // Stateless — all configuration comes from ToolCall arguments at execute time.
}

///|
/// Canonical constructor. Use this everywhere.
pub fn WriteTools::WriteTools() -> WriteTools {
  WriteTools::{  }
}

///|
/// File-system IO boundary for the `write` tool.
///
/// `@fs` is native-only, so each target supplies its own adaptor. The shared
/// `execute_write_impl` below talks only to this trait.
priv trait FsIo {
  /// Write text content to a file (create or truncate). Raise on IO failure.
  async fn write_text(self : Self, path : String, content : String) -> Unit raise @posoco.RuntimeError
}

///|
/// Shared tool list for the `write` tool. Both native and js WriteTools expose
/// the same tool definition; only the IO adaptor differs per target.
fn shared_list_tools() -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("write"),
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
      owner: @posoco.OwnerId::unchecked("posoco_ext_write"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("posoco_ext_write"),
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

///|
/// Shared `write` execute logic. Target-agnostic; only the IO adaptor differs.
async fn execute_write_impl(
  io : &FsIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let (path, content) = extract_path_content(call.arguments)
  io.write_text(path, content)
  @posoco.ToolOutcome::Success(
    content="Wrote \{content.length()} bytes to \{path}",
    structured=None,
  )
}
