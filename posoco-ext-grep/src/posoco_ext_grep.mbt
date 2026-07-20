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
/// Record the precise stage before aborting `@fs.walk`. The walk API wraps
/// callback failures, so the caller reads this side channel instead of
/// serializing the underlying OS error (which may contain sensitive data).
fn[T] abort_file(
  failures : Array[String],
  stage : String,
  path : String,
) -> T raise Failure {
  failures.push("grep: \{stage} failed for '\{@devkit.sanitize_path(path)}'")
  raise Failure::Failure("grep aborted")
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
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "grep: 'pattern' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("grep: missing 'pattern'")
      }
      let b = match obj.get("path") {
        Some(String(s)) => s
        None => "."
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "grep: optional 'path' must be a string",
          )
      }
      let g = match obj.get("glob") {
        Some(String(s)) => s
        None => ""
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "grep: optional 'glob' must be a string",
          )
      }
      (p, b, g)
    }
    _ => raise @posoco.RuntimeError::UnknownTool("grep: invalid arguments")
  }
  // Collect matching lines. Walk sequentially so the first failure and its
  // diagnostic are deterministic and no callback can race after cancellation.
  let results : Array[String] = []
  let failures : Array[String] = []
  @fs.walk(
    base,
    (dir : String, entries : Array[String]) => {
      for entry in entries {
        let full = if dir == "." { entry } else { "\{dir}/\{entry}" }
        // Skip if glob filter doesn't match
        if file_glob != "" && !file_matches(full, file_glob) {
          continue
        }
        // `walk` includes directory names in `entries`; inspect the kind so
        // directories are deliberately skipped while stat errors stay loud.
        let kind = @fs.kind(full) catch {
          _ => abort_file(failures, "stat", full)
        }
        if kind == @fs.FileKind::Directory {
          continue
        }
        let data = @fs.read_file(full) catch {
          _ => abort_file(failures, "read", full)
        }
        let content = data.text() catch {
          _ => abort_file(failures, "decode", full)
        }
        // Search line by line
        let mut line_num = 0
        for line in content.split("\n") {
          line_num += 1
          if line.contains(pattern) {
            results.push("\{full}:\{line_num}:\{line}")
          }
        }
      }
    },
    max_concurrency=1,
  ) catch {
    _ =>
      match failures {
        [message, ..] => raise @posoco.RuntimeError::InvocationFailed(message)
        [] =>
          raise @posoco.RuntimeError::InvocationFailed(
            "grep: walk failed for '\{@devkit.sanitize_path(base)}'",
          )
      }
  }
  // Build result
  if results.length() == 0 {
    return @posoco.ToolResult::{
      content: "No matches found for: \{pattern}",
      structured: None,
      is_error: false,
    }
  }
  let builder = StringBuilder::new()
  for r in results {
    builder.write_string(r)
    builder.write_char('\n')
  }
  @posoco.ToolResult::{
    content: "Found \{results.length()} matches:\n\{builder.to_string()}",
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
