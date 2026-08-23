///|
/// Native env lookup. `moonbitlang/x/sys`'s `get_env_var` is deprecated in
/// favour of `moonbitlang/core/env` (plan R4); the semantics are identical,
/// the replacement is adopted directly.
pub fn runner_get_env(name : String) -> String? {
  @env.get_env_var(name)
}

///|
/// Native `NmemRunner`: `nmem` via `moonbitlang/async/process` (stdout and
/// stderr collected separately), home files via `moonbitlang/async/fs`.
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
  @async.with_timeout(timeout_ms, () => {
    let (exit, stdout_data, stderr_data) = @process.collect_output("nmem", args) catch {
      err => return cli_error_outcome("nmem spawn failed", err)
    }
    let stdout = stdout_data.text() catch { _ => "" }
    let stderr = stderr_data.text() catch { _ => "" }
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
      let data = @fs.read_file(home + "/" + rel) catch { _ => return None }
      let text = data.text() catch { _ => return None }
      Some(text)
    }
  }
}
