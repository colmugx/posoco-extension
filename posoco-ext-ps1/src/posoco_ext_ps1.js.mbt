///|
// js backend: node:child_process via #module injection. `@js_async.Promise::wait`
// returns the fulfilled value and raises on rejection — catch with try/catch.

///|
#external
priv type NodeSpawnOptions

///|
#external
priv type ShellProc

///|
#external
priv type Ps1Collect

///|
#module("node:child_process")
extern "js" fn cp_spawn(
  file : String,
  args : FixedArray[String],
  options : NodeSpawnOptions,
) -> ShellProc = "spawn"

///|
/// Spawn `<exe> -NoProfile -NonInteractive -Command <cmd>` with piped
/// stdout+stderr; empty `cwd` inherits the process working directory. The
/// exit promise resolves on the process `exit` event, not `close`: a
/// detached grandchild inheriting the pipe must not block exit-code
/// delivery. Output is buffered with getters so a post-exit grace window can
/// hand back partial text while the grandchild still holds the stream. Each
/// spawn joins a process-exit sweep so a fatal host exit cannot orphan the
/// child.
extern "js" fn node_spawn_powershell(
  spawn : (String, FixedArray[String], NodeSpawnOptions) -> ShellProc,
  exe : String,
  cmd : String,
  cwd : String,
) -> ShellProc =
  #| (spawn, exe, cmd, cwd) => {
  #|   const proc = spawn(exe, ["-NoProfile", "-NonInteractive", "-Command", cmd], { stdio: ["ignore", "pipe", "pipe"], ...(cwd ? { cwd } : {}) })
  #|   const kill = (signal) => { try { if (proc.pid) proc.kill(signal) } catch {} }
  #|   const key = Symbol.for("posoco.ps1.activeChildren")
  #|   let children = globalThis[key]
  #|   if (!children) {
  #|     children = globalThis[key] = new Set()
  #|     process.once("exit", () => {
  #|       for (const terminate of children) {
  #|         try { terminate("SIGKILL") } catch {}
  #|       }
  #|     })
  #|   }
  #|   children.add(kill)
  #|   proc.once("exit", () => children.delete(kill))
  #|   const exited = new Promise((resolve) => {
  #|     proc.on("exit", (code) => resolve(code ?? -1))
  #|     proc.on("error", () => resolve(-1))
  #|   })
  #|   const so = [""]
  #|   const se = [""]
  #|   if (proc.stdout) {
  #|     proc.stdout.setEncoding("utf8")
  #|     proc.stdout.on("data", (chunk) => { so[0] += chunk })
  #|   }
  #|   if (proc.stderr) {
  #|     proc.stderr.setEncoding("utf8")
  #|     proc.stderr.on("data", (chunk) => { se[0] += chunk })
  #|   }
  #|   const closedOf = (stream) => stream
  #|     ? new Promise((resolve) => {
  #|         stream.on("end", resolve)
  #|         stream.on("close", resolve)
  #|         stream.on("error", resolve)
  #|       })
  #|     : Promise.resolve()
  #|   return { proc, kill, exited, stdoutText: () => so[0], stderrText: () => se[0], stdoutClosed: closedOf(proc.stdout), stderrClosed: closedOf(proc.stderr) }
  #| }

///|
/// Resolve with the exit code and buffered output once the streams have
/// closed after exit — or after `grace_ms` if a detached grandchild keeps
/// the streams open, whichever comes first.
extern "js" fn ShellProc::collect(
  self : ShellProc,
  grace_ms : Int32,
) -> @js_async.Promise[Ps1Collect] =
  #| (handle, graceMs) => new Promise((resolve) => {
  #|   handle.exited.then((code) => {
  #|     const finish = () => resolve({ code, out: handle.stdoutText(), err: handle.stderrText() })
  #|     const timer = setTimeout(finish, Math.max(0, graceMs))
  #|     Promise.all([handle.stdoutClosed, handle.stderrClosed]).then(() => { clearTimeout(timer); finish() })
  #|   })
  #| })

///|
extern "js" fn Ps1Collect::exit_code(self : Ps1Collect) -> Int32 =
  #| (collect) => collect.code

///|
extern "js" fn Ps1Collect::stdout_text(self : Ps1Collect) -> String =
  #| (collect) => collect.out

///|
extern "js" fn Ps1Collect::stderr_text(self : Ps1Collect) -> String =
  #| (collect) => collect.err

///|
/// Memoized exit promise, attached at spawn. A death by signal or a failed
/// spawn resolves -1.
extern "js" fn ShellProc::exit_promise(
  self : ShellProc,
) -> @js_async.Promise[Int32] =
  #| (handle) => handle.exited

///|
extern "js" fn ShellProc::kill_term(self : ShellProc) -> Unit =
  #| (handle) => handle.kill("SIGTERM")

///|
extern "js" fn ShellProc::kill_hard(self : ShellProc) -> Unit =
  #| (handle) => handle.kill("SIGKILL")

///|
/// JS child handle; `exited` marks a settled exit promise so unwind cleanup
/// can skip an already-dead child.
struct Ps1ChildHandle {
  proc : ShellProc
  mut exited : Bool
}

///|
fn ps1_child_interrupt(handle : Ps1ChildHandle) -> Unit {
  handle.proc.kill_term()
}

///|
async fn ps1_child_await_exit(
  handle : Ps1ChildHandle,
  timeout_ms : Int32,
) -> Bool {
  // The exit promise is memoized; waiting it again from the cancellation
  // path is safe and resolves once the signalled child dies.
  let outcome : Int32? = @async.with_timeout_opt(timeout_ms, async fn() {
    handle.proc.exit_promise().wait() catch {
      _ => -1
    }
  })
  match outcome {
    Some(_) => {
      handle.exited = true
      true
    }
    None => false
  }
}

///|
fn ps1_child_hard_kill(handle : Ps1ChildHandle) -> Unit noraise {
  handle.proc.kill_hard()
}

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
  // Register the cancellable facet before spawning so an abort racing the
  // spawn still routes to this provider.
  (ctx.register_cancel)(self as &@posoco.ToolCancellable)
  let cwd = match self.anchor {
    Some(anchor) => anchor.root
    None => ""
  }
  let proc = node_spawn_powershell(cp_spawn, self.exe, cmd, cwd)
  let handle : Ps1ChildHandle = { proc, exited: false, }
  let key = ctx.effect_id.to_int()
  self.in_flight[key] = handle
  // Unwind (abort watcher or a host-level hard cancel of the turn
  // coroutine): signal now; the registration stays behind so a later
  // `PowerShellTools::cancel` can escalate to a hard kill.
  defer (if !handle.exited { proc.kill_term() })
  // The collect wait MUST pass an abort controller: a bare `wait` parks the
  // coroutine in a cancel-protected suspension, so an aborted turn would
  // hang until the child exits on its own. With the controller, the
  // suspension unwinds on cancellation and the deferred kill above runs.
  let wait_controller = @js_async.AbortController::new()
  let waited : Result[Ps1Collect, Error] = Ok(
    proc.collect(ps1_drain_grace_ms).wait(abort_controller=wait_controller),
  ) catch {
    error => Err(error)
  }
  match waited {
    Err(_) => {
      handle.exited = true
      self.in_flight.remove(key)
      raise @posoco.RuntimeError::InvocationFailed("powershell: process failed")
    }
    Ok(collect) => {
      handle.exited = true
      self.in_flight.remove(key)
      let stdout = collect.stdout_text()
      let stderr = collect.stderr_text()
      let exit_code = collect.exit_code()
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
  }
}
