///|
/// posoco_ext_grep.js.mbt — js target (bun) implementation.
///
/// Provides the GrepSearcher adaptor (backed by `Bun.spawn` invoking `rg`)
/// and the GrepTools struct + ToolProvider impl that delegates business logic
/// to `execute_grep_impl`.
///
/// Why rg: writing an in-process recursive walker + regex engine in MoonBit
/// for the js target is substantial; delegating to rg matches native-side
/// semantics and performance. A pure-MoonBit fallback is a future task.

// ---------------------------------------------------------------------------
// Bun FFI bindings.
// ---------------------------------------------------------------------------

///|
#external
priv type BunProc

///|
/// Spawn `rg` with the given argv (no shell). Returns the process handle.
/// `--line-number --color=never --no-heading --with-filename` gives stable
/// `path:line:content` output across platforms.
extern "js" fn bun_spawn_rg(args : Array[String], cwd : String) -> BunProc =
  #| (args, cwd) => Bun.spawn({
  #|   cmd: ["rg", "--line-number", "--color=never", "--no-heading", "--with-filename", ...args],
  #|   cwd: cwd || undefined,
  #|   stdout: "pipe",
  #|   stderr: "pipe",
  #| })

///|
extern "js" fn BunProc::exit_code(self : BunProc) -> @js_async.Promise[Int] =
  #| (proc) => proc.exited

///|
extern "js" fn BunProc::stdout_text(
  self : BunProc,
) -> @js_async.Promise[String] =
  #| (proc) => new Response(proc.stdout).text()

///|
extern "js" fn BunProc::stderr_text(
  self : BunProc,
) -> @js_async.Promise[String] =
  #| (proc) => new Response(proc.stderr).text()

///|
/// Build the rg argv tail (pattern + optional glob + base path).
fn build_rg_args(
  pattern : String,
  base : String,
  file_glob : String,
) -> Array[String] {
  let args : Array[String] = [pattern]
  if file_glob != "" {
    args.push("--glob")
    args.push(file_glob)
  }
  args.push(base)
  args
}

// ---------------------------------------------------------------------------
// JsGrepSearcher — rg-backed adaptor.
// ---------------------------------------------------------------------------

///|
priv struct JsGrepSearcher {}

///|
/// Delegate search to ripgrep and parse `path:line:content` output.
impl GrepSearcher for JsGrepSearcher with fn search(
  _self,
  pattern : String,
  base : String,
  file_glob : String,
) -> Array[String] {
  let args = build_rg_args(pattern, base, file_glob)
  let proc = bun_spawn_rg(args, base)
  let exit_code = proc.exit_code().wait() catch {
      _ =>
        // Most likely: rg is not installed. Bun.spawn throws ENOENT before
        // exit_code can settle. Surface a loud, actionable error.
        raise @posoco.RuntimeError::InvocationFailed(
          "grep: failed to spawn rg (is ripgrep installed on PATH?) for '\{@devkit.sanitize_path(base)}'",
        )
    }
  // rg exit codes: 0 = matches found, 1 = no matches, 2 = error.
  // Read both streams regardless so diagnostics are not lost.
  let stdout = proc.stdout_text().wait() catch { _ => "" }
  let stderr = proc.stderr_text().wait() catch { _ => "" }
  if exit_code == 2 {
    raise @posoco.RuntimeError::InvocationFailed(
      "grep: rg error for '\{@devkit.sanitize_path(base)}': " + stderr,
    )
  }
  // exit_code 0 (matches) or 1 (no matches) — both are normal outcomes.
  // rg output is already in `path:line:content` form; normalize trailing newline.
  let results : Array[String] = []
  for line in stdout.split("\n") {
    if line.length() > 0 {
      results.push(line.to_owned())
    }
  }
  results
}

// ---------------------------------------------------------------------------
// GrepTools — js struct + ToolProvider impl.
// ---------------------------------------------------------------------------

///|
/// GrepTools — content search tool provider (js target).
pub(all) struct GrepTools {}

///|
pub fn GrepTools::new() -> GrepTools {
  GrepTools::{  }
}

///|
pub impl @posoco.ToolProvider for GrepTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  shared_list_tools()
}

///|
/// Execute the `grep` tool on js. Business logic lives in the shared
/// `execute_grep_impl`; this method only supplies the rg-based searcher.
pub impl @posoco.ToolProvider for GrepTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  execute_grep_impl(JsGrepSearcher::{  }, call)
}
