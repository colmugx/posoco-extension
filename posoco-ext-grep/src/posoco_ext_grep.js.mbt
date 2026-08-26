// Why rg: writing an in-process recursive walker + regex engine in MoonBit
// for the js target is substantial; delegating to rg matches native-side
// semantics and performance.
//
// js (bun) target: spawn through Bun.spawn and drain stdout/stderr via
// Response(...).text(), bridged with @js_async so the calling coroutine
// suspends instead of blocking the JS event loop (a synchronous spawnSync
// froze rendering and input for the duration of every rg run). The spawn
// result crosses the FFI as one JSON string envelope (see posoco-ext-read's
// js adaptor and docs/questions.md 2026-08-19).

///|
/// `Bun.which("rg") != null` — whether rg is on PATH. Never throws for a
/// string argument; a plain Bool pass-through (no Option encoding on the
/// FFI boundary).
extern "js" fn bun_has_rg() -> Bool =
  #| () => Bun.which("rg") != null

///|
/// Spawn with piped streams and await exit + both drains concurrently.
/// cwd is inherited (the base path is passed to rg as an argument, so a
/// relative base resolves against the host cwd — the same reference frame
/// the walker tools use). The async arrow returns a JS Promise, bridged by
/// `.wait()` on the MoonBit side.
extern "js" fn js_spawn_envelope(
  cmd : Array[String],
) -> @js_async.Promise[String] =
  #| async (cmd) => {
  #|   const proc = Bun.spawn(cmd, { stdout: "pipe", stderr: "pipe" });
  #|   const [exitCode, stdout, stderr] = await Promise.all([
  #|     proc.exited,
  #|     new Response(proc.stdout).text(),
  #|     new Response(proc.stderr).text(),
  #|   ]);
  #|   return JSON.stringify({ ok: true, exitCode, stdout, stderr });
  #| }

///|
/// Decoded spawn envelope.
priv struct JsRgResult {
  exit_code : Int
  stdout : String
  stderr : String
}

///|
/// Await the spawn envelope. `noraise`: both the JSON parse and the promise
/// rejection are caught here, so callers see a plain envelope value.
async fn js_spawn_result(cmd : Array[String]) -> JsRgResult noraise {
  let json : Json = @json.parse(js_spawn_envelope(cmd).wait()) catch {
    _ =>
      return {
        exit_code: 2,
        stdout: "",
        stderr: "spawn envelope decode failed",
      }
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ =>
      return {
        exit_code: 2,
        stdout: "",
        stderr: "spawn envelope is not an object",
      }
  }
  let exit_code = match fields.get("exitCode") {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => 2
  }
  let stdout = match fields.get("stdout") {
    Some(Json::String(text)) => text
    _ => ""
  }
  let stderr = match fields.get("stderr") {
    Some(Json::String(text)) => text
    _ => ""
  }
  { exit_code, stdout, stderr }
}

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

///|
priv struct JsGrepSearcher {}

///|
/// Delegate search to ripgrep and parse `path:line:content` output.
impl GrepSearcher for JsGrepSearcher with fn search(
  _self : JsGrepSearcher,
  pattern : String,
  base : String,
  file_glob : String,
) -> Array[String] {
  // Fail loudly and actionably before spawning when rg is not on PATH.
  if !bun_has_rg() {
    raise @posoco.RuntimeError::InvocationFailed(
      "grep: failed to spawn rg (is ripgrep installed on PATH?) for '\{@devkit.sanitize_path(base)}'",
    )
  }
  let argv : Array[String] = [
    "rg", "--line-number", "--color=never", "--no-heading", "--with-filename",
  ]
  for arg in build_rg_args(pattern, base, file_glob) {
    argv.push(arg)
  }
  let result = js_spawn_result(argv)
  // rg exit codes: 0 = matches found, 1 = no matches, 2 = error.
  // Read both streams regardless so diagnostics are not lost.
  if result.exit_code == 2 {
    raise @posoco.RuntimeError::InvocationFailed(
      "grep: rg error for '\{@devkit.sanitize_path(base)}': " + result.stderr,
    )
  }
  // exit_code 0 (matches) or 1 (no matches) — both are normal outcomes.
  // rg output is already in `path:line:content` form; normalize trailing newline.
  let results : Array[String] = []
  for line in result.stdout.split("\n") {
    if line.length() > 0 {
      results.push(line.to_owned())
    }
  }
  results
}

///|
pub impl @posoco.ToolProvider for GrepTools with fn list_tools(self : GrepTools) -> Array[
  @posoco.ToolDef,
] {
  shared_list_tools()
}

///|
/// Execute the `grep` tool on js. Business logic lives in the shared
/// `execute_grep_impl`; this method only supplies the rg-based searcher.
pub impl @posoco.ToolProvider for GrepTools with fn execute(
  self : GrepTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_grep_impl(JsGrepSearcher::{  }, self.anchor, call)
}
