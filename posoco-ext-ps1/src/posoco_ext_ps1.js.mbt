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
/// Spawn `<exe> -NoProfile -NonInteractive -Command <cmd>` with piped
/// stdout+stderr. Synchronous in bun. An empty `cwd` inherits the bun process
/// working directory. The command string is passed verbatim — all quoting and
/// parsing belongs to PowerShell, not the spawn layer.
extern "js" fn bun_spawn_powershell(
  exe : String,
  cmd : String,
  cwd : String,
) -> BunProc =
  #| (exe, cmd, cwd) => Bun.spawn({ cmd: [exe, "-NoProfile", "-NonInteractive", "-Command", cmd], stdout: "pipe", stderr: "pipe", ...(cwd ? { cwd } : {}) })

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
pub impl @posoco.ToolProvider for PowerShellTools with fn list_tools(
  self : PowerShellTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools(self.exe)
}

///|
pub impl @posoco.ToolProvider for PowerShellTools with fn execute(
  self : PowerShellTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let cmd = extract_command(call.arguments)
  if cmd == "" {
    raise ps1_empty_command_failure()
  }
  let cwd = match self.anchor {
    Some(anchor) => anchor.root
    None => ""
  }
  let proc = bun_spawn_powershell(self.exe, cmd, cwd)
  let exit_code = proc.exit_code().wait() catch {
      _ =>
        raise @posoco.RuntimeError::InvocationFailed(
          "powershell: process failed (stage=wait_exit)",
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
