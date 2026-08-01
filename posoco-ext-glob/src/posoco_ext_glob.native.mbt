///|
// ============================================================================
// posoco_ext_glob_native.mbt — ToolProvider for native target.
//
// Active on: target="native"
// Provides:  NativeGlobScanner (@fs.walk + MoonBit glob-matching engine) and
//            the complete ToolProvider impl (list_tools + execute).
// ============================================================================

// ---------------------------------------------------------------------------
// Native scanner — @fs.walk + MoonBit glob-matching engine.
// ---------------------------------------------------------------------------

///|
priv struct NativeGlobScanner {}

///|
/// Walk the directory tree and collect paths matching the glob pattern.
impl GlobScanner for NativeGlobScanner with fn scan(
  _self,
  pattern : String,
  base : String,
) -> Array[String] {
  let matches : Array[String] = []
  @fs.walk(base, fn(dir : String, entries : Array[String]) {
    for entry in entries {
      let full = if dir == "." { entry } else { "\{dir}/\{entry}" }
      if glob_match(pattern, full) {
        matches.push(full)
      }
    }
  }) catch {
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        "glob: walk failed for '\{@devkit.sanitize_path(base)}'",
      )
  }
  matches
}

// ---------------------------------------------------------------------------
// Glob-matching engine (native-only; js delegates to Bun.Glob).
// ---------------------------------------------------------------------------

///|
/// Match a path against a glob pattern. Supports * and **.
/// `*` matches any characters except `/`; `**` matches any path segments.
fn glob_match(pattern : String, path : String) -> Bool {
  let pat_segs = pattern.split("/").to_array()
  let path_segs = path.split("/").to_array()
  match_segments(pat_segs, 0, path_segs, 0)
}

///|
fn match_segments(
  pat : Array[StringView],
  pi : Int,
  path : Array[StringView],
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
fn seg_match(pat_seg : StringView, path_seg : StringView) -> Bool {
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

// ---------------------------------------------------------------------------
// ToolProvider — complete impl (list_tools + execute) for native.
// ---------------------------------------------------------------------------

///|
/// Execute the `glob` tool on native. Business logic lives in the shared
/// `execute_glob_impl`; this method only supplies the walk-based scanner.
pub impl @posoco.ToolProvider for GlobTools with fn list_tools(
  _self : GlobTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
pub impl @posoco.ToolProvider for GlobTools with fn execute(
  _self : GlobTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_glob_impl(NativeGlobScanner::{  }, call)
}
