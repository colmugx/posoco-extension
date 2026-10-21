///|
/// Native child handle. Teardown escalation (signal → grace → hard kill)
/// lives in the spawn's `graceful_cancel` handler, which the local task
/// group runs when the effect task is cancelled; `PowerShellTools::cancel`
/// only needs to trigger the same handler and wait out the grace period.
struct Ps1ChildHandle {
  proc : @process.Process
  mut exited : Bool
}

///|
fn ps1_child_interrupt(handle : Ps1ChildHandle) -> Unit {
  handle.proc.cancel()
}

///|
async fn ps1_child_await_exit(
  handle : Ps1ChildHandle,
  timeout_ms : Int32,
) -> Bool {
  let outcome : Int32? = @async.with_timeout_opt(timeout_ms, async fn() {
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
async fn ps1_child_hard_kill(handle : Ps1ChildHandle) -> Unit noraise {
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
  // cwd is passed explicitly (never inherited) when an anchor is set, so the
  // child cannot drift from the workspace root the model was told about.
  let cwd : StringView? = match self.anchor {
    Some(anchor) => Some(anchor.root)
    None => None
  }
  let pipes = @process.read_from_process() catch {
    _ => raise ps1_collect_output_failure()
  }
  let (reader, writer) = pipes
  let key = ctx.effect_id.to_int()
  let attempted : Result[(Int32, String, Bool), Error] = Ok(
    @async.with_task_group(async fn(group) {
      defer reader.close()
      let proc = @process.spawn(
        group,
        self.exe,
        ["-NoProfile", "-NonInteractive", "-Command", cmd],
        stdout=writer,
        stderr=writer,
        cwd?,
        cancel_handler=@process.graceful_cancel(timeout=ps1_cancel_grace_ms),
      )
      let handle : Ps1ChildHandle = { proc, exited: false, }
      self.in_flight[key] = handle
      let exit_code = proc.wait()
      handle.exited = true
      self.in_flight.remove(key)
      let output = ps1_read_drained(reader)
      let mut decode_failed = false
      let data : &@io.Data = output
      let content = data.text() catch {
        _ => {
          decode_failed = true
          ps1_decode_failure(exit_code)
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
        "powershell: process failed: " + error.to_string(),
      )
    }
    Ok((exit_code, content, decode_failed)) => {
      let content = ps1_model_output(content, exit_code)
      let is_error = exit_code != 0 || decode_failed
      if is_error {
        @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
      } else {
        @posoco.ToolOutcome::Success(content~, structured=None)
      }
    }
  }
}

///|
/// Upper bound on post-exit drain volume. Model-visible output is capped far
/// below this; the bound only stops a pathological pipe-holder from growing
/// memory without limit.
const PS1_DRAIN_BYTE_CAP : Int64 = 67_108_864L

///|
const PS1_READ_CHUNK_BYTES : Int32 = 8192

///|
/// Read merged child output after the child has exited. Returns at EOF, or —
/// when a detached grandchild keeps the inherited pipe write-end open — once
/// the drain has stayed silent for `ps1_drain_grace_ms`, so the call returns
/// the buffered output instead of hanging forever. Forward progress re-arms
/// the idle window so a fast producer is not cut off mid-log.
async fn ps1_read_drained(reader : @process.ReadFromProcess) -> Bytes {
  let chunks : Array[Bytes] = []
  let buf : FixedArray[Byte] = FixedArray::make(PS1_READ_CHUNK_BYTES, b'\x00')
  let mut deadline = @async.now() + ps1_drain_grace_ms.to_int64()
  let mut total : Int64 = 0L
  let mut eof = false
  while !eof {
    let remaining = deadline - @async.now()
    if remaining <= 0L || total >= PS1_DRAIN_BYTE_CAP {
      break
    }
    let got : Int32? = @async.with_timeout_opt(remaining.to_int(), async fn() {
      reader.read(buf)
    })
    match got {
      None => eof = true
      Some(n) =>
        if n <= 0 {
          eof = true
        } else {
          chunks.push(Bytes::from_array(buf[0:n]))
          total += n.to_int64()
          deadline = @async.now() + ps1_drain_grace_ms.to_int64()
        }
    }
  }
  let buffer = @buffer.Buffer::Buffer()
  for chunk in chunks {
    buffer.write_bytes(chunk[:])
  }
  buffer.to_bytes()
}

///|
/// Native decode failure — non-UTF-8 output must not masquerade as success.
fn ps1_decode_failure(_exit_code : Int32) -> String {
  "powershell: invalid UTF-8"
}

///|
/// Native collect_output failure.
fn ps1_collect_output_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed("powershell: process failed")
}
