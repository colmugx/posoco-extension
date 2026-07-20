///|
/// ReadTools — file reading tool provider.
/// Reads a file's contents and returns them as text.

///|
pub(all) struct ReadTools {}

///|
pub fn ReadTools::new() -> ReadTools {
  ReadTools::{  }
}

///|
fn read_failure(stage : String, path : String) -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "read: \{stage} failed for '\{@devkit.sanitize_path(path)}'",
  )
}

///|
pub impl @posoco.ToolProvider for ReadTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
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
pub impl @posoco.ToolProvider for ReadTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  // Extract path from arguments
  let path = match call.arguments {
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
  // Check existence
  let exists = @fs.exists(path) catch { _ => raise read_failure("stat", path) }
  if !exists {
    return @posoco.ToolResult::{
      content: "File not found: \{@devkit.sanitize_path(path)}",
      structured: None,
      is_error: true,
    }
  }
  // Read file
  let data = @fs.read_file(path) catch { _ => raise read_failure("read", path) }
  let content = data.text() catch { _ => raise read_failure("decode", path) }
  @posoco.ToolResult::{ content, structured: None, is_error: false }
}
