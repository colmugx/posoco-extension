// js execution face for the shared pipeline: node:child_process + node:fs via #module
// injection, env reads via the `process` global; anything throwing crosses the FFI as
// a JSON string envelope decoded with @json (empty-string sentinels stand in for
// "missing").
//
// The stage budget is enforced HERE, extern-side: the spawn helper races the child's
// exit against a setTimeout that kills it and resolves `timed_out`, raised as the
// package-local `MbtxBudgetExpired` marker that `timed_stage` classifies as a timeout.

///|
extern "js" fn js_env_raw(name : String) -> String =
  #| (name) => process.env[name] ?? ""

///|
#module("node:fs")
extern "js" fn fs_access_sync(path : String, mode : Int) -> Unit = "accessSync"

///|
/// Executable `name` within exactly the given directory (js counterpart of
/// `@fs.can_execute`): accessSync(X_OK) is executability on POSIX and mere
/// existence on Windows, where PATHEXT candidates cover the shims.
extern "js" fn js_which_in(
  access : (String, Int) -> Unit,
  name : String,
  dir : String,
) -> String =
  #| (access, name, dir) => {
  #|   const isWin = process.platform === "win32"
  #|   const exts = isWin ? (process.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").split(";") : []
  #|   const candidates = [name, ...exts.map((ext) => name + ext)]
  #|   const base = dir === ""
  #|     ? ""
  #|     : dir.endsWith("/") || dir.endsWith("\\") ? dir : dir + (isWin ? "\\" : "/")
  #|   for (const candidate of candidates) {
  #|     const path = base + candidate
  #|     try {
  #|       access(path, 1) // fs.constants.X_OK
  #|       return path
  #|     } catch {}
  #|   }
  #|   return ""
  #| }

///|
/// One timed subprocess: literal argv (no shell), piped stdout+stderr, merged
/// result envelope; `cwd` "" inherits the process working directory. A budget
/// expiry kills the child (SIGTERM), waits up to 1s for the pipes to drain, and
/// reports `timed_out` with no output (native reports no output on timeout either).
extern "js" fn js_runner_envelope(
  spawn : (String, FixedArray[String], NodeSpawnOptions) -> NodeProc,
  cmd : String,
  args : FixedArray[String],
  cwd : String,
  timeout_ms : Int,
) -> @js_async.Promise[String] =
  #| async (spawn, cmd, args, cwd, timeout_ms) => {
  #|   let proc;
  #|   try {
  #|     proc = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"], ...(cwd ? { cwd } : {}) });
  #|   } catch (e) {
  #|     return JSON.stringify({ ok: false, timed_out: false, code: 0, stdout: "", stderr: "", message: String(e) });
  #|   }
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
  #|   const stdout_p = drain(proc.stdout)
  #|   const stderr_p = drain(proc.stderr)
  #|   const exited = new Promise((resolve) => {
  #|     proc.on("close", (code) => resolve({ timed_out: false, code: code ?? 0, wait_error: "" }))
  #|     proc.on("error", (err) => resolve({ timed_out: false, code: 0, wait_error: String(err) }))
  #|   })
  #|   let timer = null;
  #|   const budget = new Promise((resolve) => {
  #|     timer = setTimeout(() => resolve({ timed_out: true, code: 0, wait_error: "" }), timeout_ms);
  #|   });
  #|   const outcome = await Promise.race([exited, budget]);
  #|   if (timer) clearTimeout(timer);
  #|   if (outcome.timed_out) {
  #|     try { proc.kill(); } catch (kill_err) {}
  #|     const grace = new Promise((resolve) => setTimeout(() => resolve(null), 1000));
  #|     await Promise.race([Promise.all([stdout_p, stderr_p]), grace]);
  #|     return JSON.stringify({ ok: true, timed_out: true, code: 0, stdout: "", stderr: "", message: "" });
  #|   }
  #|   const stdout = await stdout_p;
  #|   const stderr = await stderr_p;
  #|   return JSON.stringify({ ok: outcome.wait_error === "", timed_out: false, code: outcome.code, stdout, stderr, message: outcome.wait_error });
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
#module("node:fs")
extern "js" fn fs_mkdtemp_sync(prefix : String) -> String = "mkdtempSync"

///|
#module("node:fs")
extern "js" fn fs_write_file_sync(path : String, content : String) -> Unit = "writeFileSync"

///|
/// rmSync's 2nd argument is a JS options object, so the declared parameter is
/// only a value-passing shape; the envelope builds `{ recursive: true, force: true }`.
#module("node:fs")
extern "js" fn fs_rm_sync(path : String, recursive : Bool) -> Unit = "rmSync"

///|
#module("node:fs")
extern "js" fn fs_realpath_sync(path : String) -> String = "realpathSync"

///|
extern "js" fn js_mktmpdir_envelope(
  mkdtemp : (String) -> String,
  prefix : String,
) -> String =
  #| (mkdtemp, prefix) => {
  #|   try {
  #|     const base = process.env.TMPDIR || process.env.TMP || "/tmp";
  #|     return JSON.stringify({ ok: true, dir: mkdtemp(`${base}/${prefix}`) });
  #|   } catch (e) {
  #|     return JSON.stringify({ ok: false, message: String(e) });
  #|   }
  #| }

///|
extern "js" fn js_write_file_envelope(
  write_file : (String, String) -> Unit,
  path : String,
  content : String,
) -> String =
  #| (writeFile, path, content) => {
  #|   try { writeFile(path, content); return JSON.stringify({ ok: true }); }
  #|   catch (e) { return JSON.stringify({ ok: false, message: String(e) }); }
  #| }

///|
extern "js" fn js_rm_rf_envelope(
  rm : (String, Bool) -> Unit,
  path : String,
) -> String =
  #| (rm, path) => {
  #|   try { rm(path, { recursive: true, force: true }); return JSON.stringify({ ok: true }); }
  #|   catch (e) { return JSON.stringify({ ok: false, message: String(e) }); }
  #| }

///|
extern "js" fn js_realpath_envelope(
  realpath : (String) -> String,
  path : String,
) -> String =
  #| (realpath, path) => {
  #|   try { return JSON.stringify({ ok: true, path: realpath(path) }); }
  #|   catch (e) { return JSON.stringify({ ok: false, path: path }); }
  #| }

///|
/// Decoded spawn envelope. `ok=false` covers spawn failures and exit-wait
/// errors; `timed_out=true` means the budget killed the child.
priv struct JsStageResult {
  ok : Bool
  timed_out : Bool
  code : Int
  stdout : String
  stderr : String
  message : String
}

///|
fn js_envelope_fields(envelope : String) -> Map[String, Json]? {
  let json = @json.parse(envelope) catch { _ => return None }
  match json {
    Json::Object(map) => Some(map)
    _ => None
  }
}

///|
fn js_fields_str(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(Json::String(s)) => s
    _ => ""
  }
}

///|
fn js_fields_bool(fields : Map[String, Json], key : String) -> Bool {
  match fields.get(key) {
    Some(Json::True) => true
    _ => false
  }
}

///|
fn decode_js_stage_result(envelope : String) -> JsStageResult {
  match js_envelope_fields(envelope) {
    Some(fields) =>
      {
        ok: js_fields_bool(fields, "ok"),
        timed_out: js_fields_bool(fields, "timed_out"),
        code: match fields.get("code") {
          Some(Json::Number(value, ..)) => value.to_int()
          _ => 0
        },
        stdout: js_fields_str(fields, "stdout"),
        stderr: js_fields_str(fields, "stderr"),
        message: js_fields_str(fields, "message"),
      }
    None =>
      {
        ok: false,
        timed_out: false,
        code: 0,
        stdout: "",
        stderr: "",
        message: "mbtx: spawn envelope decode failed",
      }
  }
}

///|
/// Merged stage output: stdout, then stderr appended when both are
/// non-empty (keeps the artifacts_path JSON line intact).
fn js_merge_output(stdout : String, stderr : String) -> String {
  if stderr.length() > 0 {
    if stdout.length() > 0 {
      stdout + "\n" + stderr
    } else {
      stderr
    }
  } else {
    stdout
  }
}

///|
/// The production Runner on js: one timed subprocess. Spawn failures propagate as
/// generic errors (timed_stage adds the stage context); the budget expiry raises the
/// `MbtxBudgetExpired` marker, which timed_stage classifies with the timeout family —
/// the child was already killed extern-side.
priv struct JsRunner {}

///|
impl Runner for JsRunner with fn run(
  _self : JsRunner,
  cmd : String,
  args : Array[String],
  cwd : String?,
  budget_ms : Int,
) -> (Int, String, Bool) {
  let cwd_arg = match cwd {
    Some(dir) => dir
    None => ""
  }
  let envelope = js_runner_envelope(
    cp_spawn,
    cmd,
    FixedArray::from_array(args),
    cwd_arg,
    budget_ms,
  ).wait() catch {
    _ => raise Failure::Failure("mbtx: js spawn bridge rejected the stage")
  }
  let result = decode_js_stage_result(envelope)
  if !result.ok {
    raise Failure::Failure(result.message)
  }
  if result.timed_out {
    raise MbtxBudgetExpired::Expired
  }
  // Response.text() never yields invalid UTF-8 (replacement chars), so the
  // decoded_ok channel is always true on js.
  (result.code, js_merge_output(result.stdout, result.stderr), true)
}

///|
fn mbtx_default_runner() -> &Runner {
  JsRunner::{ }
}

///|
/// The call's one-shot temp directory (mkdtemp-style dir under TMPDIR, same
/// shape as the native `@fs.tmpdir` face).
fn mbtx_call_tmpdir() -> String raise @posoco.RuntimeError {
  let fields = match
    js_envelope_fields(js_mktmpdir_envelope(fs_mkdtemp_sync, "posoco-mbtx-")) {
    Some(fields) => fields
    None =>
      raise @posoco.RuntimeError::InvocationFailed(
        "mbtx: could not create the call temp dir: envelope decode failed",
      )
  }
  let dir = js_fields_str(fields, "dir")
  if js_fields_bool(fields, "ok") && dir != "" {
    return dir
  }
  raise @posoco.RuntimeError::InvocationFailed(
    "mbtx: could not create the call temp dir: \{js_fields_str(fields, "message")}",
  )
}

///|
fn mbtx_write_file(
  path : String,
  content : String,
) -> Unit raise @posoco.RuntimeError {
  let fields = match
    js_envelope_fields(
      js_write_file_envelope(fs_write_file_sync, path, content),
    ) {
    Some(fields) => fields
    None =>
      raise @posoco.RuntimeError::InvocationFailed(
        "mbtx: could not write '\{path}': envelope decode failed",
      )
  }
  if !js_fields_bool(fields, "ok") {
    raise @posoco.RuntimeError::InvocationFailed(
      "mbtx: could not write '\{path}': \{js_fields_str(fields, "message")}",
    )
  }
}

///|
/// Best-effort recursive cleanup; a failed cleanup is never fatal (the dir
/// lives under the system temp location either way).
#warnings("-unused_error_type")
fn mbtx_cleanup_tmpdir(tmpdir : String) -> Unit raise @posoco.RuntimeError {
  ignore(js_rm_rf_envelope(fs_rm_sync, tmpdir))
}

///|
/// Best-effort realpath for BUILD-diagnostic hygiene; callers swallow the
/// failure and keep the raw path. (async to stay call-compatible with the
/// native edge, whose @fs realpath is async; pragma: no js await points.)
#warnings("-unused_async")
async fn mbtx_realpath(path : String) -> String {
  match js_envelope_fields(js_realpath_envelope(fs_realpath_sync, path)) {
    Some(fields) =>
      if js_fields_bool(fields, "ok") {
        let resolved = js_fields_str(fields, "path")
        if resolved != "" {
          return resolved
        }
      }
    None => ()
  }
  raise Failure::Failure("mbtx: realpath failed")
}

///|
/// js env read: a missing variable is the "" sentinel, turned into None to
/// match the native `@env.get_env_var : String?` face (docs/questions.md
/// 2026-08-23: never `T?` across the FFI). HOME only, like native — no
/// USERPROFILE fallback on either side.
fn mbtx_js_env(name : String) -> String? {
  let value = js_env_raw(name)
  if value == "" {
    None
  } else {
    Some(value)
  }
}

///|
/// Host-environment toolchain edge (see `toolchain.mbt`): the override /
/// Bun's PATH / Bun's HOME `~/.moon/bin`, probed in that order.
async fn MbtxTools::ensure_toolchain(
  self : MbtxTools,
) -> ResolvedToolchain raise @posoco.RuntimeError {
  self.ensure_toolchain_from(
    path_env=mbtx_js_env("PATH"),
    home_dir=mbtx_js_env("HOME"),
  )
}

///|
/// A candidate is usable only when BOTH `moon` and `moonrun` are executable
/// within it (`Bun.which` against that one directory — executability, not
/// mere existence; never throws, so no envelope needed). (async to mirror
/// the native edge's call shape; pragma: no js await points.)
#warnings("-unused_async")
async fn toolchain_dir_usable(bin_dir : String) -> Bool noraise {
  js_which_in(fs_access_sync, "moon", bin_dir) != "" &&
  js_which_in(fs_access_sync, "moonrun", bin_dir) != ""
}
