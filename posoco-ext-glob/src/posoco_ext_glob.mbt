///|
/// GlobTools — file pattern matching tool provider.
/// Walks a directory tree and returns paths matching a glob-like pattern.
/// Supports `*` (any chars in one segment) and `**` (recursive).

///|
pub(all) struct GlobTools {}

///|
pub fn GlobTools::new() -> GlobTools {
  GlobTools::{  }
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
pub impl @posoco.ToolProvider for GlobTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  [
    @posoco.ToolDef::{
      name: "glob",
      description: "Find files matching a glob pattern. Supports * (single segment wildcard) and ** (recursive). Example: '**/*.mbt' finds all .mbt files recursively.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "pattern": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "Glob pattern (e.g. '**/*.mbt', 'src/*.mbt')",
            ),
          }),
          "path": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "Base directory to search (default: '.')",
            ),
          }),
        }),
        "required": Json::array([Json::string("pattern")]),
      }),
      metadata: None,
      source: Some("posoco_ext_glob"),
    },
  ]
}

///|
pub impl @posoco.ToolProvider for GlobTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let (pattern, base) = match call.arguments {
    Object(obj) => {
      let p = match obj.get("pattern") {
        Some(String(s)) => s
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "glob: 'pattern' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::UnknownTool("glob: missing 'pattern'")
      }
      let b = match obj.get("path") {
        Some(String(s)) => s
        None => "."
        Some(_) =>
          raise @posoco.RuntimeError::UnknownTool(
            "glob: optional 'path' must be a string",
          )
      }
      (p, b)
    }
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "glob: arguments must be a JSON object",
      )
  }
  // Walk the directory tree and collect matches
  let matches : Array[String] = []
  @fs.walk(base, fn(dir : String, entries : Array[String]) {
    for entry in entries {
      let full = if dir == "." { entry } else { dir + "/" + entry }
      if glob_match(pattern, full) {
        matches.push(full)
      }
    }
  }) catch {
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        "glob: walk failed for '" + diagnostic_path(base) + "'",
      )
  }
  // Build result text
  let builder = StringBuilder::new()
  for m in matches {
    builder.write_string(m)
    builder.write_char('\n')
  }
  let count = matches.length().to_string()
  @posoco.ToolResult::{
    content: "Found " + count + " files:\n" + builder.to_string(),
    structured: None,
    is_error: false,
  }
}

///|
/// Match a path against a glob pattern. Supports * and **.
/// `*` matches any characters except `/`; `**` matches any path segments.
fn glob_match(pattern : String, path : String) -> Bool {
  let pat_segs = pattern.split("/").map(fn(s) { s.to_owned() }).collect()
  let path_segs = path.split("/").map(fn(s) { s.to_owned() }).collect()
  match_segments(pat_segs, 0, path_segs, 0)
}

///|
fn match_segments(
  pat : Array[String],
  pi : Int,
  path : Array[String],
  si : Int,
) -> Bool {
  if pi >= pat.length() {
    return si >= path.length()
  }
  if pat[pi] == "**" {
    // ** matches zero or more path segments
    // Try matching the rest of the pattern at every position
    let mut next = si
    while true {
      if match_segments(pat, pi + 1, path, next) {
        return true
      }
      if next >= path.length() {
        return false
      }
      next += 1
    }
    return false // unreachable
  }
  if si >= path.length() {
    return false
  }
  if seg_match(pat[pi], path[si]) {
    return match_segments(pat, pi + 1, path, si + 1)
  }
  false
}

///|
/// Match a single path segment against a pattern segment (with * wildcards).
fn seg_match(pat_seg : String, path_seg : String) -> Bool {
  if !pat_seg.contains("*") {
    return pat_seg == path_seg
  }
  // Simple wildcard matching for single segment
  wildcard_match(pat_seg.iter().collect(), 0, path_seg.iter().collect(), 0)
}

///|
fn wildcard_match(
  pat : Array[Char],
  pi : Int,
  text : Array[Char],
  ti : Int,
) -> Bool {
  if pi >= pat.length() {
    return ti >= text.length()
  }
  if pat[pi] == '*' {
    // * matches zero or more chars
    let mut next = ti
    while true {
      if wildcard_match(pat, pi + 1, text, next) {
        return true
      }
      if next >= text.length() {
        return false
      }
      next += 1
    }
    return false // unreachable
  }
  if ti >= text.length() {
    return false
  }
  if pat[pi] == text[ti] {
    return wildcard_match(pat, pi + 1, text, ti + 1)
  }
  false
}
