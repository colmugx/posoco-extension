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
/// Kill the child with the named signal ("SIGTERM" / "SIGKILL" / ...).
extern "js" fn BunProc::kill(self : BunProc, signal : String) -> Unit =
  #| (proc, signal) => { try { proc.kill(signal) } catch {} }

///|
/// Kill the child with bun's default signal (SIGTERM).
extern "js" fn BunProc::kill_default(self : BunProc) -> Unit =
  #| (proc) => { try { proc.kill() } catch {} }

///|
/// JS child handle: the bun subprocess. `exited` marks a settled `exited`
/// promise so unwind cleanup can skip an already-dead child.
struct ShellChildHandle {
  proc : BunProc
  mut exited : Bool
}

///|
fn shell_child_interrupt(handle : ShellChildHandle) -> Unit {
  handle.proc.kill_default()
}

///|
async fn shell_child_await_exit(
  handle : ShellChildHandle,
  timeout_ms : Int,
) -> Bool {
  // `proc.exited` is a memoized promise; waiting it again from the
  // cancellation path is safe and resolves once the signalled child dies
  // (a killed child resolves with null / rejects — both mean "exited").
  let outcome : Int? = @async.with_timeout_opt(timeout_ms, async fn() {
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
  let proc = bun_spawn_shell(cmd, cwd)
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
  let waited : Result[Int, Error] = Ok(
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
