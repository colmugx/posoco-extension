///|
/// Native child handle. Teardown escalation (signal → grace → hard kill)
/// lives in the spawn's `graceful_cancel` handler, which the local task
/// group runs when the effect task is cancelled; `ShellTools::cancel` only
/// needs to trigger the same handler and wait out the grace period.
struct ShellChildHandle {
  proc : @process.Process
  mut exited : Bool
}

///|
fn shell_child_interrupt(handle : ShellChildHandle) -> Unit {
  handle.proc.cancel()
}

///|
async fn shell_child_await_exit(
  handle : ShellChildHandle,
  timeout_ms : Int,
) -> Bool {
  let outcome : Int? = @async.with_timeout_opt(timeout_ms, async fn() {
    handle.proc.wait() catch {
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
async fn shell_child_hard_kill(handle : ShellChildHandle) -> Unit noraise {
  // `kill_process` is not exported directly; invoking the exported
  // `hard_cancel` handler's function is the public hard-kill seam. The
  // handler's signature is raising; the underlying kill is synchronous, so
  // the catch is purely for the type.
  let pid = handle.proc.pid
  let kill = @process.hard_cancel().0
  let outcome : Result[Unit, Error] = Ok(kill(pid)) catch {
    error => Err(error)
  }
  ignore(outcome)
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
  // cwd is passed explicitly (never inherited) when an anchor is set, so the
  // child cannot drift from the workspace root the model was told about.
  let cwd : StringView? = match self.anchor {
    Some(anchor) => Some(anchor.root)
    None => None
  }
  let pipes = @process.read_from_process() catch {
    _ => raise bash_collect_output_failure()
  }
  let (reader, writer) = pipes
  let key = ctx.effect_id.to_int()
  let attempted : Result[(Int, String, Bool), Error] = Ok(
    @async.with_task_group(async fn(group) {
      defer reader.close()
      let proc = @process.spawn(
        group,
        "sh",
        ["-c", cmd],
        stdout=writer,
        stderr=writer,
        cwd?,
        cancel_handler=@process.graceful_cancel(timeout=shell_cancel_grace_ms),
      )
      let handle : ShellChildHandle = { proc, exited: false, }
      self.in_flight[key] = handle
      let exit_code = proc.wait()
      handle.exited = true
      self.in_flight.remove(key)
      let output = reader.read_all()
      let mut decode_failed = false
      let content = output.text() catch {
        _ => {
          decode_failed = true
          ""
        }
      }
      (exit_code, content, decode_failed)
    }),
  ) catch {
    error => Err(error)
  }
  match attempted {
    Err(error) => {
      self.in_flight.remove(key)
      raise @posoco.RuntimeError::InvocationFailed(
        "bash: process failed: " + error.to_string(),
      )
    }
    Ok((exit_code, content, decode_failed)) => {
      let content = if decode_failed {
        bash_decode_failure(exit_code)
      } else {
        bash_model_output(content, exit_code)
      }
      if exit_code != 0 || decode_failed {
        @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
      } else {
        @posoco.ToolOutcome::Success(content~, structured=None)
      }
    }
  }
}

///|
/// Native decode failure — non-UTF-8 output must not masquerade as success.
fn bash_decode_failure(_exit_code : Int) -> String {
  "bash: invalid UTF-8"
}

///|
fn bash_collect_output_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed("bash: process failed")
}
