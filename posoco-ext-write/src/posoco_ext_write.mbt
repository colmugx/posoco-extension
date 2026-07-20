///|
/// WriteTools — file writing tool provider.
/// Writes text content to a file (creates or truncates).

///|
pub(all) struct WriteTools {}

///|
pub fn WriteTools::new() -> WriteTools {
  WriteTools::{  }
}

///|
fn write_failure(path : String) -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "write: write failed for '\{@devkit.sanitize_path(path)}'",
  )
}

///|
pub impl @posoco.ToolProvider for WriteTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
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
pub impl @posoco.ToolProvider for WriteTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let (path, content) = match call.arguments {
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
  let data = content
  @fs.write_file(path, data) catch {
    _ => raise write_failure(path)
  }
  @posoco.ToolResult::{
    content: "Wrote \{content.length()} bytes to \{path}",
    structured: None,
    is_error: false,
  }
}
