///|
/// GrepTools — content search tool provider.
/// Searches for a pattern in files under a directory and returns matching lines.

///|
pub(all) struct GrepTools {}

///|
pub fn GrepTools::new() -> GrepTools {
  GrepTools::{  }
}

///|
pub impl @posoco.ToolProvider for GrepTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  [
    @posoco.ToolDef::{
      name: "grep",
      description: "Search for a text pattern in files. Returns matching lines with file paths and line numbers. Searches recursively under the given path.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "pattern": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Text pattern to search for"),
          }),
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Directory to search in (default: '.')"),
          }),
          "glob": Json::object({
            "type": Json::string("string"),
            "description": Json::string("File pattern filter (e.g. '*.mbt')"),
          }),
        }),
        "required": Json::array([Json::string("pattern")]),
      }),
      metadata: None,
      source: Some("posoco_ext_grep"),
    },
  ]
}

///|
pub impl @posoco.ToolProvider for GrepTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let (pattern, base, file_glob) = match call.arguments {
    Object(obj) => {
      let p = match obj.get("pattern") {
        Some(String(s)) => s
        _ => raise @posoco.RuntimeError::UnknownTool("grep: missing 'pattern'")
      }
      let b = match obj.get("path") {
        Some(String(s)) => s
        _ => "."
      }
      let g = match obj.get("glob") {
        Some(String(s)) => s
        _ => ""
      }
      (p, b, g)
    }
    _ => raise @posoco.RuntimeError::UnknownTool("grep: invalid arguments")
  }
  // Collect matching lines
  let results : Array[String] = []
  @fs.walk(base, (dir : String, entries : Array[String]) => {
    for entry in entries {
      let full = if dir == "." { entry } else { dir + "/" + entry }
      // Skip if glob filter doesn't match
      if file_glob != "" && !file_matches(full, file_glob) {
        continue
      }
      // Try to read as text
      let exists = @fs.exists(full) catch { _ => false }
      if !exists {
        continue
      }
      let data = @fs.read_file(full) catch { _ => return }
      let content = data.text() catch { _ => return }
      // Search line by line
      let mut line_num = 0
      for line in content.split("\n") {
        line_num += 1
        if line.contains(pattern) {
          results.push(
            full + ":" + line_num.to_string() + ": " + line.to_owned(),
          )
        }
      }
    }
  }) catch {
    e => raise @posoco.RuntimeError::InvocationFailed("grep: walk failed: \{e}")
  }
  // Build result
  if results.length() == 0 {
    return @posoco.ToolResult::{
      content: "No matches found for: " + pattern,
      structured: None,
      is_error: false,
    }
  }
  let builder = StringBuilder::new()
  for r in results {
    builder.write_string(r)
    builder.write_char('\n')
  }
  let count = results.length().to_string()
  @posoco.ToolResult::{
    content: "Found " + count + " matches:\n" + builder.to_string(),
    structured: None,
    is_error: false,
  }
}

///|
/// Check if a file path matches a simple glob (e.g. "*.mbt").
fn file_matches(path : String, glob : String) -> Bool {
  if glob.has_prefix("*.") {
    let ext = glob[2:].to_owned()
    return path.has_suffix("." + ext)
  }
  path == glob
}
