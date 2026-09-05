// js (bun) execution face for the shared pipeline. Process spawning goes
// through Bun globals (Bun.spawn / Bun.which / Bun.env — never
// node:child_process); file IO goes through node:fs sync APIs. Everything
// throwing crosses the FFI as a JSON string envelope decoded with @json on
// the MoonBit side (docs/questions.md 2026-08-19: `-> T raise` externs are
// runtime-broken and `T?`/Error mappings are not used; empty-string
// sentinels stand in for "missing").
//
// The stage budget is enforced HERE, extern-side: on js the pipeline's
// @async timing layer cannot kill a child it does not own, so the spawn
// helper races `proc.exited` against a setTimeout that kills the child and
// resolves a `timed_out` outcome. The runner raises the package-local
// `MbtxBudgetExpired` marker for it, which `timed_stage` classifies into
// the same "timed out" business error as on native/wasm.

///|
extern "js" fn js_env_raw(name : String) -> String =
  #| (name) => Bun.env[name] ?? ""

///|
/// `Bun.which` checks executability (not mere existence) within exactly the
/// given PATH entry — the js counterpart of `@fs.can_execute`. It is
/// synchronous and never throws, so a plain value passthrough is safe.
extern "js" fn js_which_in(name : String, dir : String) -> String =
  #| (name, dir) => Bun.which(name, { PATH: dir }) ?? ""

///|
/// One timed subprocess: literal argv (no shell anywhere), piped
/// stdout+stderr, merged result envelope. `cwd` "" inherits the process
/// working directory. A budget expiry kills the child (SIGTERM), waits up
/// to 1s for the pipes to drain, and reports `timed_out` with no output
/// (timed-out stages report no output on native either).
extern "js" fn js_runner_envelope(
  cmd : String,
  args : FixedArray[String],
  cwd : String,
  timeout_ms : Int,
) -> @js_async.Promise[String] =
  #| async (cmd, args, cwd, timeout_ms) => {
  #|   let proc;
  #|   try {
  #|     proc = Bun.spawn({ cmd: [cmd, ...args], stdout: "pipe", stderr: "pipe", ...(cwd ? { cwd } : {}) });
  #|   } catch (e) {
  #|     return JSON.stringify({ ok: false, timed_out: false, code: 0, stdout: "", stderr: "", message: String(e) });
  #|   }
  #|   let timer = null;
  #|   const exited = proc.exited.then(
  #|     (code) => ({ timed_out: false, code, wait_error: "" }),
  #|     (err) => ({ timed_out: false, code: 0, wait_error: String(err) })
  #|   );
  #|   const budget = new Promise((resolve) => {
  #|     timer = setTimeout(() => resolve({ timed_out: true, code: 0, wait_error: "" }), timeout_ms);
  #|   });
  #|   const outcome = await Promise.race([exited, budget]);
  #|   if (timer) clearTimeout(timer);
  #|   if (outcome.timed_out) {
  #|     try { proc.kill(); } catch (kill_err) {}
  #|     const grace = new Promise((resolve) => setTimeout(() => resolve(null), 1000));
  #|     const drain = (async () => {
  #|       const stdout = await new Response(proc.stdout).text().catch(() => "");
  #|       const stderr = await new Response(proc.stderr).text().catch(() => "");
  #|       return { stdout, stderr };
  #|     })();
  #|     await Promise.race([drain, grace]);
  #|     return JSON.stringify({ ok: true, timed_out: true, code: 0, stdout: "", stderr: "", message: "" });
  #|   }
  #|   const stdout = await new Response(proc.stdout).text().catch(() => "");
  #|   const stderr = await new Response(proc.stderr).text().catch(() => "");
  #|   return JSON.stringify({ ok: outcome.wait_error === "", timed_out: false, code: outcome.code, stdout, stderr, message: outcome.wait_error });
  #| }

///|
extern "js" fn js_mktmpdir_envelope(prefix : String) -> String =
  #| (prefix) => {
  #|   const fs = require("node:fs");
  #|   const path = require("node:path");
  #|   try {
  #|     const base = Bun.env.TMPDIR || Bun.env.TMP || "/tmp";
  #|     return JSON.stringify({ ok: true, dir: fs.mkdtempSync(path.join(base, prefix)) });
  #|   } catch (e) {
  #|     return JSON.stringify({ ok: false, message: String(e) });
  #|   }
  #| }

///|
extern "js" fn js_write_file_envelope(
  path : String,
  content : String,
) -> String =
  #| (path, content) => {
  #|   const fs = require("node:fs");
  #|   try { fs.writeFileSync(path, content); return JSON.stringify({ ok: true }); }
  #|   catch (e) { return JSON.stringify({ ok: false, message: String(e) }); }
  #| }

///|
extern "js" fn js_rm_rf_envelope(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try { fs.rmSync(path, { recursive: true, force: true }); return JSON.stringify({ ok: true }); }
  #|   catch (e) { return JSON.stringify({ ok: false, message: String(e) }); }
  #| }

///|
extern "js" fn js_realpath_envelope(path : String) -> String =
  #| (path) => {
  #|   const fs = require("node:fs");
  #|   try { return JSON.stringify({ ok: true, path: fs.realpathSync(path) }); }
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
/// The production Runner on js: one timed Bun subprocess. Spawn failures
/// propagate as generic errors (timed_stage adds the stage context); the
/// budget expiry raises the `MbtxBudgetExpired` marker, which timed_stage
/// classifies with the timeout family — the child was already killed
/// extern-side.
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
    // Classified by timed_stage into the stage's "timed out" content; the
    // child has already been killed extern-side.
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
  let fields = match js_envelope_fields(js_mktmpdir_envelope("posoco-mbtx-")) {
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
  let fields = match js_envelope_fields(js_write_file_envelope(path, content)) {
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
  ignore(js_rm_rf_envelope(tmpdir))
}

///|
/// Best-effort realpath for BUILD-diagnostic hygiene; callers swallow the
/// failure and keep the raw path. (async to stay call-compatible with the
/// native edge, whose @fs realpath is async; pragma: no js await points.)
#warnings("-unused_async")
async fn mbtx_realpath(path : String) -> String {
  match js_envelope_fields(js_realpath_envelope(path)) {
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
  js_which_in("moon", bin_dir) != "" && js_which_in("moonrun", bin_dir) != ""
}
