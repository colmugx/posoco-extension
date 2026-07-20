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
/// Keep user-controlled paths bounded and single-line in diagnostics.
fn diagnostic_path(path : String) -> String {
  let builder = StringBuilder::new()
  let mut count = 0
  for ch in path {
    if count >= 160 {
      builder.write_string("...")
      break
    }
    match ch {
      '\n' | '\r' | '\t' => builder.write_char(' ')
      _ => builder.write_char(ch)
    }
    count += 1
  }
  builder.to_string()
}

///|
fn edit_failure(stage : String, path : String) -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed(
    "edit: " + stage + " failed for '" + diagnostic_path(path) + "'",
  )
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
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "edit: 'path' argument must be a string",
          )
        None => raise @posoco.RuntimeError::UnknownTool("edit: missing 'path'")
      }
      let o = match obj.get("old_text") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "edit: 'old_text' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("edit: missing 'old_text'")
      }
      let n = match obj.get("new_text") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "edit: 'new_text' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("edit: missing 'new_text'")
      }
      let ra = match obj.get("replace_all") {
        Some(True) => true
        Some(False) | None => false
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "edit: optional 'replace_all' must be a boolean",
          )
      }
      (p, o, n, ra)
    }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "edit: arguments must be a JSON object",
      )
  }
  // Read current content
  let exists = @fs.exists(path) catch { _ => raise edit_failure("stat", path) }
  if !exists {
    return @posoco.ToolResult::{
      content: "File not found: " + diagnostic_path(path),
      structured: None,
      is_error: true,
    }
  }
  let data = @fs.read_file(path) catch { _ => raise edit_failure("read", path) }
  let content = data.text() catch { _ => raise edit_failure("decode", path) }
  // Check if old_text exists
  if !content.contains(old_text) {
    return @posoco.ToolResult::{
      content: "old_text not found in " + diagnostic_path(path),
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
    _ => raise edit_failure("write", path)
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
