///|
// Bun is a global under bun: `extern "js" fn ... = #| () => Bun.xxx()` works
// without require/import (posoco-ext-bash precedent). FFI stays on the two
// proven stable boundaries (docs/questions.md 2026-08-19): pure value
// pass-through (String/Bool) and Promise bridging via `@js_async.Promise::wait`.

///|
#external
priv type BunProc

///|
/// `process.env[name] ?? ""` — pure value pass-through. Blank and missing
/// collapse here; NmemConfig::resolve treats blank as missing anyway, so the
/// shared `String?` wrapper below loses nothing.
extern "js" fn js_env_raw(name : String) -> String =
  #| (name) => process.env[name] ?? ""

///|
/// js env lookup for the shared runner surface. Home-directory resolution on
/// js goes through `process.env.HOME` (Windows hosts are a documented v1
/// limitation, plan D7).
pub fn runner_get_env(name : String) -> String? {
  let raw = js_env_raw(name)
  if raw == "" {
    None
  } else {
    Some(raw)
  }
}

///|
/// `Bun.which("nmem") != null` — whether the nmem CLI is resolvable. Guards
/// the spawn below: Bun.spawn throws synchronously for a missing executable,
/// which has no defined behavior across the FFI boundary.
extern "js" fn bun_nmem_available() -> Bool =
  #| () => Bun.which("nmem") != null

///|
/// Spawn `nmem <args...>` with piped stdout+stderr (posoco-ext-bash shape).
extern "js" fn bun_spawn_nmem(args : Array[String]) -> BunProc =
  #| (args) => Bun.spawn({ cmd: ["nmem", ...args], stdout: "pipe", stderr: "pipe" })

///|
/// `Subprocess.prototype.exited` — Promise<number> (exit code).
extern "js" fn BunProc::exit_code(self : BunProc) -> @js_async.Promise[Int] =
  #| (proc) => proc.exited

///|
/// Drain stdout as UTF-8 string via `new Response(stream).text()`.
extern "js" fn BunProc::stdout_text(
  self : BunProc,
) -> @js_async.Promise[String] =
  #| (proc) => new Response(proc.stdout).text()

///|
/// Drain stderr as UTF-8 string.
extern "js" fn BunProc::stderr_text(
  self : BunProc,
) -> @js_async.Promise[String] =
  #| (proc) => new Response(proc.stderr).text()

///|
/// `Bun.file(path).text()` — Promise<String> that rejects when the file is
/// missing or unreadable; the rejection is caught by the caller.
extern "js" fn bun_file_text(path : String) -> @js_async.Promise[String] =
  #| (path) => Bun.file(path).text()

///|
/// js (bun) `NmemRunner`: `nmem` via Bun.spawn, home files via Bun.file.
pub(all) struct PlatformRunner {
  // empty
}

///|
pub fn PlatformRunner::PlatformRunner() -> PlatformRunner {
  PlatformRunner::{  }
}

///|
fn cli_timeout_outcome() -> CliOutcome {
  { exit: NMEM_CLI_ABORT_EXIT, stdout: "", stderr: "timeout" }
}

///|
/// Normalize any error escaping the timed run into an abort outcome so the
/// degradation chain can treat "could not run" as just another failed read.
fn cli_error_outcome(context : String, err : Error) -> CliOutcome {
  {
    exit: NMEM_CLI_ABORT_EXIT,
    stdout: "",
    stderr: "\{context}: \{err.to_string()}",
  }
}

///|
pub impl NmemRunner for PlatformRunner with fn run_cli(
  _self : PlatformRunner,
  args : Array[String],
  timeout_ms~ : Int,
) -> CliOutcome {
  if !bun_nmem_available() {
    return {
      exit: NMEM_CLI_ABORT_EXIT,
      stdout: "",
      stderr: "nmem CLI not found on PATH",
    }
  }
  @async.with_timeout(timeout_ms, () => {
    let proc = bun_spawn_nmem(args)
    let exit = proc.exit_code().wait() catch { _ => NMEM_CLI_ABORT_EXIT }
    let stdout = proc.stdout_text().wait() catch { _ => "" }
    let stderr = proc.stderr_text().wait() catch { _ => "" }
    { exit, stdout, stderr }
  }) catch {
    @async.TimeoutError => cli_timeout_outcome()
    err => cli_error_outcome("nmem run failed", err)
  }
}

///|
pub impl NmemRunner for PlatformRunner with fn read_home_file(
  _self : PlatformRunner,
  rel : String,
) -> String? {
  match runner_get_env("HOME") {
    None => None
    Some(home) => {
      let text = bun_file_text(home + "/" + rel).wait() catch {
        _ => return None
      }
      Some(text)
    }
  }
}
