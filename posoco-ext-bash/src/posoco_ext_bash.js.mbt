///|
// ============================================================================
// posoco_ext_bash.js.mbt — js target (bun) adaptor + ToolProvider impl.
//
// Active on: target="js" (via moon.pkg targets)
// Provides:  Bun FFI bindings + complete ToolProvider impl (via Bun.spawn)
//
// Uses Bun's global `Bun.spawn` to run `sh -c <cmd>` with stdout+stderr piped.
// Bun is a global object under bun, so `extern "js" fn ... = #| () => Bun.xxx()`
// works without require/import. We deliberately do NOT use `node:child_process`
// because the target runtime is bun (per project decision).
//
// `@js_async.Promise::wait` is an async fn: returns the fulfilled value
// directly, and raises on rejection. Catch rejections with `try { ... }
// catch { _ => ... }`.
// ============================================================================

///|
#external
priv type BunProc

///|
/// Spawn `sh -c <cmd>` with piped stdout+stderr. Synchronous in bun.
extern "js" fn bun_spawn_shell(cmd : String) -> BunProc =
  #| (cmd) => Bun.spawn({ cmd: ["sh", "-c", cmd], stdout: "pipe", stderr: "pipe" })

///|
/// `Subprocess.prototype.exited` — Promise<number> (exit code).
extern "js" fn BunProc::exit_code(self : BunProc) -> @js_async.Promise[Int] =
  #| (proc) => proc.exited

///|
/// Drain stdout as UTF-8 string via `new Response(stream).text()`.
/// Response is a global Web API available in bun; works on any ReadableStream.
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
pub impl @posoco.ToolProvider for ShellTools with fn list_tools(
  _self : ShellTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
pub impl @posoco.ToolProvider for ShellTools with fn execute(
  _self : ShellTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let cmd = extract_command(call.arguments)
  if cmd == "" {
    raise bash_empty_command_failure()
  }
  let proc = bun_spawn_shell(cmd)
  let exit_code = proc.exit_code().wait() catch {
      _ =>
        raise @posoco.RuntimeError::InvocationFailed(
          "bash: process failed (stage=wait_exit)",
        )
    }
  let stdout = proc.stdout_text().wait() catch { _ => "" }
  let stderr = proc.stderr_text().wait() catch { _ => "" }
  let content = if stderr.length() > 0 {
    if stdout.length() > 0 {
      stdout + "\n" + stderr
    } else {
      stderr
    }
  } else {
    stdout
  }
  @posoco.ToolResult::{ content, structured: None, is_error: exit_code != 0 }
}
