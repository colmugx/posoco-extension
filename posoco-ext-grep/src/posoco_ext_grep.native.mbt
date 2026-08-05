///|

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
/// Check if a file path matches a simple glob (e.g. "*.mbt").
fn file_matches(path : String, glob : String) -> Bool {
  if glob.has_prefix("*.") {
    let ext = glob[2:].to_owned()
    return path.has_suffix("." + ext)
  }
  path == glob
}

///|
priv struct NativeGrepSearcher {}

///|
/// Walk the tree sequentially (max_concurrency=1) so the first failure and
/// its diagnostic are deterministic. Returns `path:line:content` entries.
impl GrepSearcher for NativeGrepSearcher with fn search(
  _self : NativeGrepSearcher,
  pattern : String,
  base : String,
  file_glob : String,
) -> Array[String] {
  let results : Array[String] = []
  let failures : Array[String] = []
  @fs.walk(
    base,
    (dir : String, entries : Array[String]) => {
      for entry in entries {
        let full = if dir == "." { entry } else { "\{dir}/\{entry}" }
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
  _self : GrepTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_grep_impl(NativeGrepSearcher::{  }, call)
}
