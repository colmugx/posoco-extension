// js target: ast-grep through the node:child_process envelope, banner-validated
// candidates (a look-alike shim only costs one wasted spawn); unlike grep there is
// NO in-process fallback — no real binary raises InvocationFailed with the install hint.

///|
#module("node:fs")
extern "js" fn fs_exists_sync(path : String) -> Bool = "existsSync"

///|
extern "js" fn node_which(exists : (String) -> Bool, name : String) -> String =
  #| (exists, name) => {
  #|   if (name.includes("/") || name.includes("\\")) {
  #|     try { return exists(name) ? name : "" } catch { return "" }
  #|   }
  #|   const isWin = process.platform === "win32"
  #|   const dirs = (process.env.PATH ?? "").split(isWin ? ";" : ":").filter(Boolean)
  #|   const exts = isWin
  #|     ? (process.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").split(";")
  #|     : []
  #|   const candidates = [name, ...exts.map((ext) => name + ext)]
  #|   for (const dir of dirs) {
  #|     const base = dir.endsWith("/") || dir.endsWith("\\") ? dir : dir + (isWin ? "\\" : "/")
  #|     for (const candidate of candidates) {
  #|       try { if (exists(base + candidate)) return base + candidate } catch {}
  #|     }
  #|   }
  #|   return ""
  #| }

///|
#external
priv type NodeSpawnOptions

///|
#external
priv type NodeProc

///|
#module("node:child_process")
extern "js" fn cp_spawn(
  file : String,
  args : FixedArray[String],
  options : NodeSpawnOptions,
) -> NodeProc = "spawn"

///|
/// Spawn with piped streams and await exit + both drains concurrently.
/// The drain resolves with partial text when a stream is destroyed without
/// `end` (killed child, failed spawn) — `close` on the stream is the
/// reliable terminator.
extern "js" fn js_spawn_envelope(
  spawn : (String, FixedArray[String], NodeSpawnOptions) -> NodeProc,
  cmd : FixedArray[String],
) -> @js_async.Promise[String] =
  #| async (spawn, cmd) => {
  #|   const proc = spawn(cmd[0], cmd.slice(1), { stdio: ["ignore", "pipe", "pipe"] })
  #|   const drain = (stream) => stream
  #|     ? new Promise((resolve) => {
  #|         let text = ""
  #|         const finish = () => resolve(text)
  #|         stream.setEncoding("utf8")
  #|         stream.on("data", (chunk) => { text += chunk })
  #|         stream.on("end", finish)
  #|         stream.on("close", finish)
  #|         stream.on("error", finish)
  #|       })
  #|     : Promise.resolve("")
  #|   const [exitCode, stdout, stderr] = await Promise.all([
  #|     new Promise((resolve) => {
  #|       proc.on("close", (code) => resolve(code ?? -1))
  #|       proc.on("error", () => resolve(-1))
  #|     }),
  #|     drain(proc.stdout),
  #|     drain(proc.stderr),
  #|   ])
  #|   return JSON.stringify({ ok: true, exitCode, stdout, stderr })
  #| }

///|
priv struct JsSpawnResult {
  exit_code : Int32
  stdout : String
  stderr : String
}

///|
/// Await the spawn envelope. `noraise`: both the JSON parse and the promise
/// rejection are caught here, so callers see a plain envelope value (a
/// missing binary lands here as a nonzero exit).
async fn js_spawn_result(cmd : Array[String]) -> JsSpawnResult noraise {
  let json : Json = @json.parse(
    js_spawn_envelope(cp_spawn, FixedArray::from_array(cmd)).wait(),
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
    let on_path = node_which(fs_exists_sync, name)
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
) -> (Int32, String, String) raise @posoco.RuntimeError {
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
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let call : @posoco.ToolCall = {
    call_id: ctx.call_id,
    name: ctx.name,
    arguments: ctx.arguments,
  }
  execute_astgrep_impl(JsAstGrepSpawn::{ bin: None, }, self.anchor, call)
}

///|
pub extend AstGrepTools with @posoco.ToolProvider::{list_tools}
