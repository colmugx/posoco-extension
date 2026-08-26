///|
// Bun is a global under bun: `extern "js" fn ... = #| () => Bun.xxx()` works
// without require/import. Deliberately do NOT use `node:child_process` — the
// target runtime is bun.
//
// `@js_async.Promise::wait` returns the fulfilled value directly and raises on
// rejection; catch rejections with try/catch.

///|
#external
priv type BunProc

///|
/// Spawn `sh -c <cmd>` with piped stdout+stderr. Synchronous in bun.
/// An empty `cwd` inherits the bun process working directory.
extern "js" fn bun_spawn_shell(cmd : String, cwd : String) -> BunProc =
  #| (cmd, cwd) => Bun.spawn({ cmd: ["sh", "-c", cmd], stdout: "pipe", stderr: "pipe", ...(cwd ? { cwd } : {}) })

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
  self : ShellTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let cmd = extract_command(call.arguments)
  if cmd == "" {
    raise bash_empty_command_failure()
  }
  let cwd = match self.anchor {
    Some(anchor) => anchor.root
    None => ""
  }
  let proc = bun_spawn_shell(cmd, cwd)
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
  if exit_code != 0 {
    @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
  } else {
    @posoco.ToolOutcome::Success(content~, structured=None)
  }
}
