///|
#external
priv type NodeSpawnOptions

///|
#external
priv type ShellProc

///|
#module("node:child_process")
extern "js" fn cp_spawn(
  file : String,
  args : FixedArray[String],
  options : NodeSpawnOptions,
) -> ShellProc = "spawn"

///|
/// Spawn `<exe> -NoProfile -NonInteractive -Command <cmd>` with piped stdout+stderr;
/// empty `cwd` inherits the process working directory, and the command string is
/// passed verbatim (quoting belongs to PowerShell).
extern "js" fn node_spawn_powershell(
  spawn : (String, FixedArray[String], NodeSpawnOptions) -> ShellProc,
  exe : String,
  cmd : String,
  cwd : String,
) -> ShellProc =
  #| (spawn, exe, cmd, cwd) => {
  #|   const proc = spawn(exe, ["-NoProfile", "-NonInteractive", "-Command", cmd], { stdio: ["ignore", "pipe", "pipe"], ...(cwd ? { cwd } : {}) })
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
  #|   const exited = new Promise((resolve) => {
  #|     proc.on("close", (code) => resolve(code ?? -1))
  #|     proc.on("error", () => resolve(-1))
  #|   })
  #|   return { proc, exited, stdoutText: drain(proc.stdout), stderrText: drain(proc.stderr) }
  #| }

///|
extern "js" fn ShellProc::exit_code(
  self : ShellProc,
) -> @js_async.Promise[Int32] =
  #| (handle) => handle.exited

///|
extern "js" fn ShellProc::stdout_text(
  self : ShellProc,
) -> @js_async.Promise[String] =
  #| (handle) => handle.stdoutText

///|
extern "js" fn ShellProc::stderr_text(
  self : ShellProc,
) -> @js_async.Promise[String] =
  #| (handle) => handle.stderrText

///|
pub impl @posoco.ToolProvider for PowerShellTools with fn list_tools(
  self : PowerShellTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools(self.exe)
}

///|
pub impl @posoco.ToolProvider for PowerShellTools with fn execute(
  self : PowerShellTools,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let cmd = extract_command(ctx.arguments)
  if cmd == "" {
    raise ps1_empty_command_failure()
  }
  let cwd = match self.anchor {
    Some(anchor) => anchor.root
    None => ""
  }
  let proc = node_spawn_powershell(cp_spawn, self.exe, cmd, cwd)
  let exit_code = proc.exit_code().wait() catch {
      _ =>
        raise @posoco.RuntimeError::InvocationFailed(
          "powershell: process failed",
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
  let content = ps1_model_output(content, exit_code)
  if exit_code != 0 {
    @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
  } else {
    @posoco.ToolOutcome::Success(content~, structured=None)
  }
}
