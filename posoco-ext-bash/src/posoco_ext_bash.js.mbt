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
  timeout_ms : Int32,
  on_chunk : (String) -> Unit,
) -> ShellProc =
  #| (spawn, cmd, cwd, timeoutMs, onChunk) => {
  #|   const grouped = process.platform !== "win32";
  #|   const proc = spawn("sh", ["-c", cmd], { detached: grouped, stdio: ["ignore", "pipe", "pipe"], ...(cwd ? { cwd } : {}) });
  #|   const kill = (signal) => {
  #|     if (!proc.pid) return;
  #|     try { if (grouped) process.kill(-proc.pid, signal); else proc.kill(signal); } catch {}
  #|   };
  #|   const key = Symbol.for("posoco.bash.activeChildren");
  #|   let children = globalThis[key];
  #|   if (!children) {
  #|     children = globalThis[key] = new Set();
  #|     process.once("exit", () => {
  #|       for (const terminate of children) { try { terminate("SIGKILL"); } catch {} }
  #|     });
  #|   }
  #|   children.add(kill);
  #|   let timedOut = false;
  #|   let settled = false;
  #|   let cancelTimer;
  #|   let watchdog;
  #|   const outputLimit = 32768;
  #|   const keepHead = 4096;
  #|   const marker = "\n…[cut]…\n";
  #|   // Pipe data is consumed immediately; bounded head/tail buffering prevents OOM.
  #|   const drain = (stream) => {
  #|     let text = "", truncated = false, done;
  #|     const closed = new Promise(resolve => { done = resolve; });
  #|     if (!stream) { done(); return { text: () => "", closed }; }
  #|     stream.setEncoding("utf8");
  #|     stream.on("data", chunk => {
  #|       text += chunk;
  #|       onChunk(chunk);
  #|       if (text.length > outputLimit) {
  #|         text = text.slice(0, keepHead) + marker + text.slice(-(outputLimit - keepHead - marker.length));
  #|       }
  #|     });
  #|     stream.once("end", done);
  #|     stream.once("close", done);
  #|     stream.once("error", done);
  #|     return { text: () => text, closed };
  #|   };
  #|   const out = drain(proc.stdout), err = drain(proc.stderr);
  #|   // 'exit' reports child termination, 'close' may be held open by grandchildren.
  #|   const exitCode = new Promise(resolve => {
  #|     const finish = code => {
  #|       if (settled) return;
  #|       settled = true;
  #|       clearTimeout(watchdog);
  #|       if (!timedOut) { clearTimeout(cancelTimer); children.delete(kill); }
  #|       resolve(code);
  #|     };
  #|     proc.once("exit", code => finish(code ?? -1));
  #|     proc.once("error", () => finish(-1));
  #|   });
  #|   watchdog = setTimeout(() => {
  #|     if (settled) return;
  #|     timedOut = true;
  #|     kill("SIGTERM");
  #|     cancelTimer = setTimeout(() => { kill("SIGKILL"); children.delete(kill); }, 2000);
  #|     cancelTimer.unref?.();
  #|   }, timeoutMs);
  #|   watchdog.unref?.();
  #|   const exited = exitCode.then(async code => {
  #|     // Reap the direct child even if descendants retain inherited output pipes.
  #|     await Promise.race([Promise.all([out.closed, err.closed]), new Promise(resolve => setTimeout(resolve, 1000))]);
  #|     return { code, timedOut, stdout: out.text(), stderr: err.text() };
  #|   });
  #|   const requestStop = () => {
  #|     kill("SIGTERM");
  #|     const escalation = setTimeout(() => kill("SIGKILL"), 2000);
  #|     escalation.unref?.();
  #|   };
  #|   return { proc, kill, requestStop, exited };
  #| }

///|
/// Memoized exit-code promise, attached at spawn. A death by signal or a
/// failed spawn resolves -1.
extern "js" fn ShellProc::exit_code(
  self : ShellProc,
) -> @js_async.Promise[ShellCollected] =
  #| (handle) => handle.exited

///|
#external
priv type ShellCollected

///|
extern "js" fn ShellCollected::stdout_text(self : ShellCollected) -> String =
  #| (result) => result.stdout

///|
extern "js" fn ShellCollected::stderr_text(self : ShellCollected) -> String =
  #| (result) => result.stderr

///|
extern "js" fn ShellCollected::exit_code(self : ShellCollected) -> Int32 =
  #| (result) => result.code

///|
extern "js" fn ShellCollected::timed_out(self : ShellCollected) -> Bool =
  #| (result) => result.timedOut

///|
extern "js" fn ShellProc::kill(self : ShellProc, signal : String) -> Unit =
  #| (handle, signal) => { try { handle.kill(signal) } catch {} }

///|
extern "js" fn ShellProc::kill_default(self : ShellProc) -> Unit =
  #| (handle) => { try { handle.requestStop() } catch {} }

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
  let outcome : ShellCollected? = @async.with_timeout_opt(timeout_ms, async fn() {
    handle.proc.exit_code().wait() catch {
      _ => raise Failure::Failure("bash: wait failed")
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
async fn ShellTools::bash_foreground(
  self : ShellTools,
  ctx : @posoco.ToolCallContext,
  session~ : ShellSession? = None,
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
  let timeout_ms = bash_timeout_ms(ctx.arguments)
  let on_chunk : (String) -> Unit = match session {
    Some(active) => fn(chunk) { active.append(chunk) }
    None => fn(_) { () }
  }
  let proc = node_spawn_shell(cp_spawn, cmd, cwd, timeout_ms, on_chunk)
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
  let waited : Result[ShellCollected, Error] = Ok(
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
    Ok(collected) => {
      let exit_code = collected.exit_code()
      match session {
        Some(active) => active.exit_code = Some(exit_code)
        None => ()
      }
      handle.exited = true
      self.in_flight.remove(key)
      let stdout = collected.stdout_text()
      let stderr = collected.stderr_text()
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
      if collected.timed_out() {
        @posoco.ToolOutcome::ToolReportedError(
          content="bash: timed out after \{timeout_ms}ms\n" + content,
          structured=None,
        )
      } else if exit_code != 0 {
        @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
      } else {
        @posoco.ToolOutcome::Success(content~, structured=None)
      }
    }
  }
}
