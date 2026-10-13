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
#module("node:child_process")
extern "js" fn cp_spawn(
  file : String,
  args : FixedArray[String],
  options : NodeSpawnOptions,
) -> ShellProc = "spawn"

///|
/// Spawn `sh -c <cmd>` with piped stdout+stderr; empty `cwd` inherits the process
/// working directory. Exit and drain promises attach at spawn time: node streams
/// never re-fire `end` for late listeners, and the flow reads output after awaiting exit.
extern "js" fn node_spawn_shell(
  spawn : (String, FixedArray[String], NodeSpawnOptions) -> ShellProc,
  cmd : String,
  cwd : String,
) -> ShellProc =
  #| (spawn, cmd, cwd) => {
  #|   const proc = spawn("sh", ["-c", cmd], { stdio: ["ignore", "pipe", "pipe"], ...(cwd ? { cwd } : {}) })
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
/// Memoized exit-code promise, attached at spawn. A death by signal or a
/// failed spawn resolves -1.
extern "js" fn ShellProc::exit_code(
  self : ShellProc,
) -> @js_async.Promise[Int32] =
  #| (handle) => handle.exited

///|
/// The drain promise started at spawn, so reading after exit still returns the
/// full buffered output.
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
extern "js" fn ShellProc::kill(self : ShellProc, signal : String) -> Unit =
  #| (handle, signal) => { try { handle.proc.kill(signal) } catch {} }

///|
extern "js" fn ShellProc::kill_default(self : ShellProc) -> Unit =
  #| (handle) => { try { handle.proc.kill() } catch {} }

///|
/// JS child handle; `exited` marks a settled exit promise so unwind cleanup
/// can skip an already-dead child.
struct ShellChildHandle {
  proc : ShellProc
  mut exited : Bool
}

///|
fn shell_child_interrupt(handle : ShellChildHandle) -> Unit {
  handle.proc.kill_default()
}

///|
async fn shell_child_await_exit(
  handle : ShellChildHandle,
  timeout_ms : Int32,
) -> Bool {
  // The exit promise is memoized; waiting it again from the cancellation
  // path is safe and resolves once the signalled child dies.
  let outcome : Int32? = @async.with_timeout_opt(timeout_ms, async fn() {
    handle.proc.exit_code().wait() catch {
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
fn shell_child_hard_kill(handle : ShellChildHandle) -> Unit noraise {
  handle.proc.kill("SIGKILL")
}

///|
pub impl @posoco.ToolProvider for ShellTools with fn list_tools(
  _self : ShellTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
pub impl @posoco.ToolProvider for ShellTools with fn execute(
  self : ShellTools,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let cmd = extract_command(ctx.arguments)
  if cmd == "" {
    raise bash_empty_command_failure()
  }
  // Register the cancellable facet before spawning so an abort racing the
  // spawn still routes to this provider.
  (ctx.register_cancel)(self as &@posoco.ToolCancellable)
  let cwd = match self.anchor {
    Some(anchor) => anchor.root
    None => ""
  }
  let proc = node_spawn_shell(cp_spawn, cmd, cwd)
  let handle : ShellChildHandle = { proc, exited: false, }
  let key = ctx.effect_id.to_int()
  self.in_flight[key] = handle
  // Unwind (abort watcher or a host-level hard cancel of the turn
  // coroutine): signal now; the registration stays behind so a later
  // `ShellTools::cancel` can escalate to a hard kill.
  defer (if !handle.exited { proc.kill_default() })
  // The exit wait MUST pass an abort controller: a bare `wait` parks the
  // coroutine in a cancel-protected suspension, so an aborted turn would
  // hang until the child exits on its own. With the controller, the
  // suspension unwinds on cancellation and the deferred kill above runs.
  let wait_controller = @js_async.AbortController::new()
  let waited : Result[Int32, Error] = Ok(
    proc.exit_code().wait(abort_controller=wait_controller),
  ) catch {
    error => Err(error)
  }
  match waited {
    Err(_) => {
      handle.exited = true
      self.in_flight.remove(key)
      raise @posoco.RuntimeError::InvocationFailed("bash: process failed")
    }
    Ok(exit_code) => {
      handle.exited = true
      self.in_flight.remove(key)
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
      let content = bash_model_output(content, exit_code)
      if exit_code != 0 {
        @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
      } else {
        @posoco.ToolOutcome::Success(content~, structured=None)
      }
    }
  }
}
