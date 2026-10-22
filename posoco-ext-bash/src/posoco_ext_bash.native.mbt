///|
/// Descendants may hold inherited pipe handles after the direct child exits.
const BASH_DRAIN_GRACE_MS = 1_000

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
async fn ShellTools::bash_foreground(
  self : ShellTools,
  ctx : @posoco.ToolCallContext,
  session~ : ShellSession? = None,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let cmd = extract_command(ctx.arguments)
  let timeout_ms = bash_timeout_ms(ctx.arguments)
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
  let attempted : Result[(Int32, String, Bool)?, Error] = Ok(
    @async.with_timeout_opt(timeout_ms, async fn() {
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
        let drain = group.spawn(async fn() {
          bash_drain_native(reader, session~)
        })
        let exit_code = proc.wait()
        match session {
          Some(active) => active.exit_code = Some(exit_code)
          None => ()
        }
        handle.exited = true
        self.in_flight.remove(key)
        // A detached grandchild may still hold the write end open.
        let drained : (String, Bool)? = @async.with_timeout_opt(BASH_DRAIN_GRACE_MS, async fn() {
          drain.wait()
        })
        let (content, decode_failed) = match drained {
          Some(data) => data
          None => {
            reader.close()
            ("", false)
          }
        }
        (exit_code, content, decode_failed)
      })
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
    Ok(None) => {
      // with_timeout_opt cancels the scoped task group; graceful_cancel
      // escalates the child to SIGKILL after the grace period.
      self.in_flight.remove(key)
      @posoco.ToolOutcome::ToolReportedError(
        content="bash: timed out after \{timeout_ms}ms",
        structured=Some(bash_timeout_detail(timeout_ms)),
      )
    }
    Ok(Some((exit_code, content, decode_failed))) => {
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
/// UTF-8 can be split across pipe reads. Decode the largest complete prefix
/// while retaining up to three trailing bytes for the next read. An invalid
/// sequence elsewhere marks the command as a decode failure.
fn bash_utf8_complete_prefix(data : Array[Byte]) -> (String, Int32, Bool) {
  let mut used = data.length()
  let mut drop = 0
  while drop <= 3 && used >= 0 {
    let chunk = Bytes::from_array(data[0:used])
    let decoded : Result[String, Error] = Ok(@utf8.decode(chunk)) catch {
      error => Err(error)
    }
    match decoded {
      Ok(text) => return (text, used, true)
      Err(_) => {
        used -= 1
        drop += 1
      }
    }
  }
  ("", 0, false)
}

///|
/// Drain while the child is still running. Keep bounded head-and-tail text
/// rather than the first 32 KiB, since test failures usually occur at the end.
async fn bash_drain_native(
  reader : @process.ReadFromProcess,
  session~ : ShellSession? = None,
) -> (String, Bool) {
  let mut output = ""
  let mut pending : Array[Byte] = []
  let mut decode_failed = false
  for ;; {
    let chunk = reader.read_some(max_len=8192) catch { _ => None }
    match chunk {
      None => break
      Some(data) => {
        if decode_failed {
          continue
        }
        let joined = pending.copy()
        for byte in data {
          joined.push(byte)
        }
        let (text, used, valid) = bash_utf8_complete_prefix(joined)
        if !valid {
          decode_failed = true
          continue
        }
        // Keep output bounded as chunks arrive. Reuse the current shared
        // head/tail format without the removed bash_append_output helper.
        let combined = output + text
        let total_chars = bash_char_count(combined)
        if total_chars <= BASH_OUTPUT_CHAR_CAP {
          output = combined
        } else {
          let marker = "\n…[cut]…\n"
          let tail_chars = BASH_OUTPUT_CHAR_CAP -
            BASH_OUTPUT_HEAD_CHARS -
            bash_char_count(marker)
          output = bash_take_chars(combined, BASH_OUTPUT_HEAD_CHARS) +
            marker +
            bash_tail_chars(combined, total_chars, tail_chars)
        }
        match session {
          Some(active) => active.append(text)
          None => ()
        }
        pending = []
        for i in used..<joined.length() {
          pending.push(joined[i])
        }
      }
    }
  }
  if !pending.is_empty() {
    decode_failed = true
  }
  (output, decode_failed)
}

///|
///|
/// Native decode failure — non-UTF-8 output must not masquerade as success.
fn bash_decode_failure(_exit_code : Int32) -> String {
  "bash: invalid UTF-8"
}

///|
fn bash_collect_output_failure() -> @posoco.RuntimeError {
  @posoco.RuntimeError::InvocationFailed("bash: process failed")
}
