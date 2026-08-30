///|
priv struct NativeGlobScanner {
  ignores : Array[String]
}

///|
/// Kind of `path`, or None when the stat fails (vanished or unreadable).
async fn glob_file_kind(path : String) -> @fs.FileKind? {
  Some(@fs.kind(path) catch { _ => return None })
}

///|
/// Walk the directory tree and collect file paths matching the glob pattern.
/// Hidden entries and `ignores` directories are pruned; directories are
/// never returned. Results are sorted newest-first (path ascending breaks
/// mtime ties so bulk checkouts with equal timestamps stay deterministic).
impl GlobScanner for NativeGlobScanner with fn scan(
  self : NativeGlobScanner,
  pattern : String,
  base : String,
) -> Array[String] {
  let matches : Array[String] = []
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
        match glob_file_kind(full) {
          None => continue
          Some(@fs.FileKind::Directory) => continue
          Some(_) => ()
        }
        if @devkit.glob_match(pattern, rel) {
          matches.push(full)
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
        "glob: walk failed for '\{@devkit.sanitize_path(base)}'",
      )
  }
  sort_newest_first(matches)
  matches
}

///|
/// Sort paths by mtime descending; ties fall back to path ascending.
/// A failed stat sinks the entry to the end.
async fn sort_newest_first(paths : Array[String]) -> Unit noraise {
  let stamps : Array[(Int64, Int, String)] = []
  for path in paths {
    let (s, ns) = @fs.mtime(path) catch { _ => (0L, 0) }
    stamps.push((s, ns, path))
  }
  stamps.sort_by((a, b) => {
    let (a_s, a_ns, a_path) = a
    let (b_s, b_ns, b_path) = b
    let by_time = if a_s == b_s { b_ns - a_ns } else { (b_s - a_s).to_int() }
    if by_time != 0 {
      by_time
    } else {
      a_path.compare(b_path)
    }
  })
  for i in 0..<stamps.length() {
    let (_, _, path) = stamps[i]
    paths[i] = path
  }
}

///|
/// Execute the `glob` tool on native. Business logic lives in the shared
/// `execute_glob_impl`; this method only supplies the walk-based scanner.
pub impl @posoco.ToolProvider for GlobTools with fn execute(
  self : GlobTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_glob_impl(
    NativeGlobScanner::{ ignores: self.ignores, },
    self.anchor,
    call,
  )
}

///|
pub impl @posoco.ToolProvider for GlobTools with fn list_tools(
  _self : GlobTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}
