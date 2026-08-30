///|
priv struct NativeGrepSearcher {
  ignores : Array[String]
}

///|
/// Kind of `path`, or None when the stat fails (vanished or unreadable).
async fn grep_file_kind(path : String) -> @fs.FileKind? {
  Some(@fs.kind(path) catch { _ => return None })
}

///|
/// Decoded text of `path`, or None when reading or decoding fails.
async fn grep_file_text(path : String) -> String? {
  let data = @fs.read_file(path) catch { _ => return None }
  Some(data.text() catch { _ => return None })
}

///|
/// Filter `file_glob` against the base-relative path: a glob containing "/"
/// must match the whole relative path; a bare name pattern (e.g. "*.mbt")
/// matches the basename at any depth (rg --glob parity).
fn file_glob_matches(file_glob : String, rel : String) -> Bool {
  if file_glob.contains("/") {
    return @devkit.glob_match(file_glob, rel)
  }
  let mut last = rel
  let mut start = 0
  match rel.rev_find("/") {
    Some(idx) => {
      start = idx + 1
      last = rel[start:].to_owned()
    }
    None => ()
  }
  @devkit.glob_match(file_glob, last)
}

///|
/// Walk the tree sequentially (max_concurrency=1) so result order is
/// deterministic. Hidden entries and `ignores` directories are pruned;
/// unreadable or binary-looking files are skipped (rg parity) instead of
/// failing the whole search. Returns flat `GrepMatch` entries.
impl GrepSearcher for NativeGrepSearcher with fn search(
  self : NativeGrepSearcher,
  pattern : String,
  base : String,
  file_glob : String,
  case_insensitive : Bool,
) -> Array[GrepMatch] {
  let results : Array[GrepMatch] = []
  let needle = if case_insensitive { pattern.to_lower() } else { pattern }
  @fs.walk(
    base,
    (dir : String, entries : Array[String]) => {
      for entry in entries {
        let full = if dir == "." { entry } else { "\{dir}/\{entry}" }
        if entry.has_prefix(".") {
          continue
        }
        let rel = @devkit.relative_to_base(base, full)
        if @devkit.matches_ignore(rel, self.ignores) {
          continue
        }
        let kind = grep_file_kind(full)
        if kind is None || kind is Some(@fs.FileKind::Directory) {
          continue
        }
        if file_glob != "" && !file_glob_matches(file_glob, rel) {
          continue
        }
        if is_binary_extension(full) {
          continue
        }
        let content = grep_file_text(full)
        if content is None {
          continue
        }
        let text = content.unwrap()
        if looks_binary(text) {
          continue
        }
        let mut line_num = 0
        for line in text.split("\n") {
          line_num += 1
          let hit = if case_insensitive {
            line.to_lower().contains(needle)
          } else {
            line.contains(pattern)
          }
          if hit {
            results.push(GrepMatch::{
              path: full,
              line: line_num,
              content: line.to_owned(),
            })
          }
        }
      }
    },
    exclude=dir => {
      let rel = @devkit.relative_to_base(base, dir)
      rel != "" &&
      (
        @devkit.has_hidden_segment(rel) ||
        @devkit.matches_ignore(rel, self.ignores)
      )
    },
    max_concurrency=1,
  ) catch {
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        "grep: walk failed for '\{@devkit.sanitize_path(base)}'",
      )
  }
  results
}

///|
pub impl @posoco.ToolProvider for GrepTools with fn list_tools(
  _self : GrepTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `grep` tool on native. Business logic lives in the shared
/// `execute_grep_impl`; this method only supplies the walk-based searcher.
pub impl @posoco.ToolProvider for GrepTools with fn execute(
  self : GrepTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_grep_impl(
    NativeGrepSearcher::{ ignores: self.ignores, },
    self.anchor,
    call,
  )
}
