///|
/// EditTools — file editing tool provider.
/// Performs find-and-replace within a file (single occurrence or all).

///|
pub(all) struct EditTools {}

///|
pub fn EditTools::new() -> EditTools {
  EditTools::{  }
}

///|
pub impl @posoco.ToolProvider for EditTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  [
    @posoco.ToolDef::{
      name: "edit",
      description: "Edit a file by replacing text. Finds `old_text` and replaces with `new_text`. By default replaces the first occurrence; set `replace_all` to true for all occurrences.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Path to the file to edit"),
          }),
          "old_text": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Text to find in the file"),
          }),
          "new_text": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Replacement text"),
          }),
          "replace_all": Json::object({
            "type": Json::string("boolean"),
            "description": Json::string(
              "Replace all occurrences (default: false)",
            ),
          }),
        }),
        "required": Json::array([
          Json::string("path"),
          Json::string("old_text"),
          Json::string("new_text"),
        ]),
      }),
      metadata: None,
      source: Some("posoco_ext_edit"),
    },
  ]
}

///|
pub impl @posoco.ToolProvider for EditTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let (path, old_text, new_text, all) = match call.arguments {
    Object(obj) => {
      let p = match obj.get("path") {
        Some(String(s)) => s
        _ => raise @posoco.RuntimeError::UnknownTool("edit: missing 'path'")
      }
      let o = match obj.get("old_text") {
        Some(String(s)) => s
        _ => raise @posoco.RuntimeError::UnknownTool("edit: missing 'old_text'")
      }
      let n = match obj.get("new_text") {
        Some(String(s)) => s
        _ => raise @posoco.RuntimeError::UnknownTool("edit: missing 'new_text'")
      }
      let ra = match obj.get("replace_all") {
        Some(True) => true
        _ => false
      }
      (p, o, n, ra)
    }
    _ => raise @posoco.RuntimeError::UnknownTool("edit: invalid arguments")
  }
  // Read current content
  let exists = @fs.exists(path) catch {
    e => raise @posoco.RuntimeError::InvocationFailed("edit: stat failed: \{e}")
  }
  if !exists {
    return @posoco.ToolResult::{
      content: "File not found: " + path,
      structured: None,
      is_error: true,
    }
  }
  let data = @fs.read_file(path) catch {
    e => raise @posoco.RuntimeError::InvocationFailed("edit: read failed: \{e}")
  }
  let content = data.text() catch {
    e =>
      raise @posoco.RuntimeError::InvocationFailed("edit: decode failed: \{e}")
  }
  // Check if old_text exists
  if !content.contains(old_text) {
    return @posoco.ToolResult::{
      content: "old_text not found in " + path,
      structured: None,
      is_error: true,
    }
  }
  // Perform replacement
  let new_content = if all {
    content.replace_all(old=old_text, new=new_text)
  } else {
    replace_first(content, old_text, new_text)
  }
  // Write back
  let write_data = new_content
  @fs.write_file(path, write_data) catch {
    e =>
      raise @posoco.RuntimeError::InvocationFailed("edit: write failed: \{e}")
  }
  @posoco.ToolResult::{
    content: "Edited " + path,
    structured: None,
    is_error: false,
  }
}

///|
/// Replace the first occurrence of `old` with `new` in a string.
fn replace_first(text : String, old : String, new : String) -> String {
  match text.find(old) {
    None => text
    Some(pos) => {
      let before = text[0:pos].to_owned()
      let after = text[pos + old.length():].to_owned()
      before + new + after
    }
  }
}
