// js (bun) target: spawn ast-grep through the Bun process envelope.
//
// Candidates: `ast-grep` and `sg` on PATH (via Bun.which), then the common
// Homebrew prefixes, deduplicated. Each candidate is validated by spawning
// `--version` and checking the banner, so a look-alike shim on PATH is
// rejected (rg parity). Unlike the grep extension there is NO in-process
// fallback: when no real ast-grep is found, execute raises
// InvocationFailed with the install hint. The spawn result crosses the FFI
// as one JSON string envelope (see docs/questions.md 2026-08-19).

///|
extern "js" fn bun_which(name : String) -> String =
  #| (name) => Bun.which(name) ?? ""

///|
/// Spawn with piped streams and await exit + both drains concurrently.
extern "js" fn js_spawn_envelope(
  cmd : FixedArray[String],
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
priv struct JsSpawnResult {
  exit_code : Int
  stdout : String
  stderr : String
}

///|
/// Await the spawn envelope. `noraise`: both the JSON parse and the promise
/// rejection are caught here, so callers see a plain envelope value (a
/// missing binary lands here as a nonzero exit).
async fn js_spawn_result(cmd : Array[String]) -> JsSpawnResult noraise {
  let json : Json = @json.parse(
    js_spawn_envelope(FixedArray::from_array(cmd)).wait(),
  ) catch {
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
  { exit_code, stdout, stderr, }
}

///|
/// Candidate ast-grep locations: PATH first (both binary names), then the
/// common Homebrew prefixes, deduplicated in probe order.
fn astgrep_js_candidates() -> Array[String] {
  let candidates : Array[String] = []
  for name in ["ast-grep", "sg"] {
    let on_path = bun_which(name)
    if on_path != "" && !candidates.contains(on_path) {
      candidates.push(on_path)
    }
  }
  for
    fixed in [
      "/opt/homebrew/bin/ast-grep", "/opt/homebrew/bin/sg", "/usr/local/bin/ast-grep",
      "/usr/local/bin/sg",
    ] {
    if !candidates.contains(fixed) {
      candidates.push(fixed)
    }
  }
  candidates
}

///|
/// First candidate that is a real ast-grep (banner check rejects shims).
/// Raises the install hint when every candidate fails.
async fn probe_js_astgrep() -> String raise @posoco.RuntimeError {
  let candidates = astgrep_js_candidates()
  for candidate in candidates {
    let result = js_spawn_result([candidate, "--version"])
    if result.exit_code == 0 && result.stdout.contains("ast-grep") {
      return candidate
    }
  }
  raise @posoco.RuntimeError::InvocationFailed(missing_binary_error(candidates))
}

///|
priv struct JsAstGrepSpawn {
  // Probe winner; resolved lazily on first spawn so argument validation in
  // the shared impl runs before any process is started.
  mut bin : String?
}

///|
/// Run one ast-grep argv through the envelope; the probed binary rides at
/// argv[0].
impl AstGrepSpawn for JsAstGrepSpawn with fn spawn(
  self : JsAstGrepSpawn,
  argv : Array[String],
) -> (Int, String, String) raise @posoco.RuntimeError {
  let bin = match self.bin {
    Some(bin) => bin
    None => {
      let probed = probe_js_astgrep()
      self.bin = Some(probed)
      probed
    }
  }
  let result = js_spawn_result([bin] + argv)
  (result.exit_code, result.stdout, result.stderr)
}

///|
pub impl @posoco.ToolProvider for AstGrepTools with fn list_tools(
  _self : AstGrepTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `astgrep` tool on js. Business logic lives in the shared
/// `execute_astgrep_impl`; this method only supplies the spawn backend. The
/// binary probe is lazy (first spawn), so argument errors surface without
/// the binary installed.
pub impl @posoco.ToolProvider for AstGrepTools with fn execute(
  self : AstGrepTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_astgrep_impl(JsAstGrepSpawn::{ bin: None, }, self.anchor, call)
}
