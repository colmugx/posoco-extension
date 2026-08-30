///|
/// Host command execution over the ACP v1 `terminal/*` Agent-to-Client
/// reverse calls.
///
/// In v1 the command rides `terminal/create` itself (`command` plus an
/// absolute `cwd`); there is no separate input channel. `terminal/output`
/// replies each carry the cumulative output captured so far, so `run`
/// polls it and streams the diff between snapshots through `on_output`
/// (after host-side truncation the retained window is replayed as a
/// best-effort resync). Once `exitStatus` shows up on an output reply,
/// `terminal/wait_for_exit` supplies the authoritative exit code and a
/// final drain poll collects the tail.
///
/// `terminal/release` runs exactly once on every path. Timeout and
/// cancellation first go through `terminal/kill`; cancellation keeps its
/// identity (`TerminalCancelled`), it is never folded into a host failure.
///
/// This is a plain struct adapter: it implements no posoco port and never
/// appears in an extension manifest. Interactive terminals (start, feed,
/// drain on a live handle) are future work.

///|
/// Milliseconds between `terminal/output` polls while the command runs.
const TERMINAL_POLL_INTERVAL_MS = 25

///|
/// Failures an `AcpTerminal` run can end with. `method_name` carries the
/// wire method that failed; timeout and cancellation carry the partial
/// output received so far.
pub(all) suberror AcpTerminalError {
  HostCallFailed(method_name~ : String, cause~ : @acp.AgentContextError)
  TerminalTimedOut(timeout_ms~ : Int, partial_output~ : String)
  TerminalCancelled(partial_output~ : String)
} derive(Eq, Debug)

///|
/// Outcome of a completed run: the process exit code (absent when the
/// command died by signal) and the output captured when it exited.
pub(all) struct AcpTerminalResult {
  exit_code : Int?
  output : String
} derive(Eq, Debug)

///|
pub struct AcpTerminal {
  context : @acp.AgentContext
  session_id : String
}

///|
/// Bind host terminal access to one live context and one ACP session. The
/// session id is stamped on every reverse request, so one instance must not
/// be reused across sessions.
pub fn AcpTerminal::AcpTerminal(
  context~ : @acp.AgentContext,
  session_id~ : String,
) -> AcpTerminal {
  { context, session_id, }
}

///|
/// How a run ended badly, before cleanup. `HostFailure` keeps the typed
/// context error; the other two carry the partial output received so far.
priv enum TerminalRunFailure {
  HostFailure(@acp.AgentContextError)
  TimedOut(Int, String)
  CancelledRun(String)
}

///|
/// Exit facts gathered once the command has exited.
priv struct TerminalExitRun {
  output : String
  exit_code : Int?
}

///|
/// Method name carried by any `AgentContextError` variant.
fn acp_error_method(error : @acp.AgentContextError) -> String {
  match error {
    AgentContextUnavailable(method_name~) => method_name
    AgentContextCancelled(method_name~) => method_name
    AgentContextBrokerFailure(method_name~) => method_name
    AgentContextReplyMismatch(method_name~) => method_name
  }
}

///|
/// Classify a raw error crossing a `terminal/*` call: a cancellation error
/// keeps its identity, anything else is recorded as a broker failure on the
/// named method (same convention as the SDK's `agent_context_exception`).
fn terminal_transport_failure(
  error : Error,
  method_name : String,
  partial_output : String,
) -> TerminalRunFailure {
  if @async.is_cancellation_error(error) {
    CancelledRun(partial_output)
  } else {
    HostFailure(AgentContextBrokerFailure(method_name~))
  }
}

///|
/// Map a post-cleanup run failure onto the public error type.
fn terminal_error(failure : TerminalRunFailure) -> AcpTerminalError {
  match failure {
    HostFailure(cause) =>
      HostCallFailed(method_name=acp_error_method(cause), cause~)
    TimedOut(timeout_ms, partial) =>
      TerminalTimedOut(timeout_ms~, partial_output=partial)
    CancelledRun(partial) => TerminalCancelled(partial_output=partial)
  }
}

///|
/// Stream the new part of one cumulative output snapshot. `seen` always
/// tracks the latest snapshot so error paths can report partial output
/// even without a callback.
fn terminal_emit_delta(
  on_output : ((String) -> Unit)?,
  seen : Ref[String],
  snapshot : String,
) -> Unit {
  match on_output {
    None => seen.val = snapshot
    Some(emit) => {
      if snapshot.has_prefix(seen.val) {
        let delta = snapshot[seen.val.length():].to_owned()
        if delta != "" {
          emit(delta)
        }
      } else if snapshot != "" {
        // The host truncated from the front: replay the retained window.
        emit(snapshot)
      }
      seen.val = snapshot
    }
  }
}

///|
/// One `terminal/output` poll, streamed through `on_output`.
async fn terminal_poll_once(
  context : @acp.AgentContext,
  session_id : String,
  terminal_id : String,
  on_output : ((String) -> Unit)?,
  seen : Ref[String],
) -> Result[@acp.TerminalOutputResult, TerminalRunFailure] noraise {
  let params : @acp.TerminalOutputParams = {
    session_id,
    terminal_id,
    meta: Omitted,
  }
  let polled = Ok(context.terminal_output(params)) catch {
    AgentContextCancelled(_) => Err(CancelledRun(seen.val))
    error =>
      Err(
        if @async.is_cancellation_error(error) {
          CancelledRun(seen.val)
        } else {
          HostFailure(error)
        },
      )
  }
  match polled {
    Err(failure) => Err(failure)
    Ok(result) => {
      terminal_emit_delta(on_output, seen, result.output)
      Ok(result)
    }
  }
}

///|
/// Sleep one poll interval; a cancellation error raised by the sleep keeps
/// its identity.
async fn terminal_sleep(
  pause_ms : Int,
  seen : Ref[String],
) -> Result[Unit, TerminalRunFailure] noraise {
  Ok(@async.sleep(pause_ms)) catch {
    error => Err(terminal_transport_failure(error, "terminal/output", seen.val))
  }
}

///|
/// Park until the next poll, bounded by the overall deadline.
async fn terminal_park(
  started : Int64,
  timeout_ms : Int?,
  seen : Ref[String],
) -> Result[Unit, TerminalRunFailure] noraise {
  match timeout_ms {
    None => terminal_sleep(TERMINAL_POLL_INTERVAL_MS, seen)
    Some(limit) => {
      let elapsed = (@async.now() - started).to_int()
      let remaining = limit - elapsed
      if remaining <= 0 {
        Err(TimedOut(limit, seen.val))
      } else if remaining < TERMINAL_POLL_INTERVAL_MS {
        terminal_sleep(remaining, seen)
      } else {
        terminal_sleep(TERMINAL_POLL_INTERVAL_MS, seen)
      }
    }
  }
}

///|
/// Drive one created terminal to exit: poll `terminal/output` until its
/// `exitStatus` appears, then `terminal/wait_for_exit` for the
/// authoritative code, then one drain poll for the output tail.
async fn terminal_drive(
  context : @acp.AgentContext,
  session_id : String,
  terminal_id : String,
  on_output : ((String) -> Unit)?,
  timeout_ms : Int?,
) -> Result[TerminalExitRun, TerminalRunFailure] noraise {
  let seen : Ref[String] = { val: "", }
  let started = @async.now()
  let mut failure : TerminalRunFailure? = None
  let mut exit_seen = false
  while failure is None && !exit_seen {
    if @async.is_being_cancelled() {
      failure = Some(CancelledRun(seen.val))
    } else {
      match
        terminal_poll_once(context, session_id, terminal_id, on_output, seen) {
        Err(poll_failure) => failure = Some(poll_failure)
        Ok(result) =>
          if result.exit_status is Value(_) {
            exit_seen = true
          } else {
            match terminal_park(started, timeout_ms, seen) {
              Err(park_failure) => failure = Some(park_failure)
              Ok(_) => ()
            }
          }
      }
    }
  }
  match failure {
    Some(run_failure) => Err(run_failure)
    None => {
      let wait_params : @acp.TerminalWaitForExitParams = {
        session_id,
        terminal_id,
        meta: Omitted,
      }
      let waited = Ok(context.terminal_wait_for_exit(wait_params)) catch {
        AgentContextCancelled(_) => Err(CancelledRun(seen.val))
        error =>
          Err(
            if @async.is_cancellation_error(error) {
              CancelledRun(seen.val)
            } else {
              HostFailure(error)
            },
          )
      }
      match waited {
        Err(wait_failure) => Err(wait_failure)
        Ok(wait_result) =>
          match
            terminal_poll_once(
              context, session_id, terminal_id, on_output, seen,
            ) {
            Err(drain_failure) => Err(drain_failure)
            Ok(_) =>
              Ok({
                output: seen.val,
                exit_code: match wait_result.exit_code {
                  Value(code) =>
                    if code <= 2147483647UL {
                      Some(code.to_int())
                    } else {
                      None
                    }
                  _ => None
                },
              })
          }
      }
    }
  }
}

///|
/// Best-effort kill plus release. Protected from cancellation so the
/// terminal does not leak host-side when the owning task is being
/// cancelled; the original run failure always wins over cleanup failures.
async fn terminal_cleanup(
  context : @acp.AgentContext,
  session_id : String,
  terminal_id : String,
) -> Unit {
  @async.protect_from_cancel(() => {
    let kill_params : @acp.TerminalKillParams = {
      session_id,
      terminal_id,
      meta: Omitted,
    }
    ignore(context.terminal_kill(kill_params)) catch {
      _ => ()
    }
    let release_params : @acp.TerminalReleaseParams = {
      session_id,
      terminal_id,
      meta: Omitted,
    }
    ignore(context.terminal_release(release_params)) catch {
      _ => ()
    }
  })
}

///|
/// `terminal/create`, classified. A failure here leaves nothing to clean up.
async fn terminal_create_call(
  context : @acp.AgentContext,
  params : @acp.TerminalCreateParams,
) -> Result[@acp.TerminalCreateResult, TerminalRunFailure] noraise {
  Ok(context.terminal_create(params)) catch {
    AgentContextCancelled(_) => Err(CancelledRun(""))
    error =>
      Err(
        if @async.is_cancellation_error(error) {
          CancelledRun("")
        } else {
          HostFailure(error)
        },
      )
  }
}

///|
/// `terminal/release` on the success path, classified with the final output.
async fn terminal_release_call(
  context : @acp.AgentContext,
  params : @acp.TerminalReleaseParams,
  partial : String,
) -> Result[@acp.TerminalReleaseResult, TerminalRunFailure] noraise {
  Ok(context.terminal_release(params)) catch {
    AgentContextCancelled(_) => Err(CancelledRun(partial))
    error =>
      Err(
        if @async.is_cancellation_error(error) {
          CancelledRun(partial)
        } else {
          HostFailure(error)
        },
      )
  }
}

///|
/// Run `command` to completion in `cwd` (an absolute path, per the v1 wire
/// contract) on the attached host terminal. `on_output` receives each new
/// output chunk in arrival order; the full text is returned either way.
/// `timeout_ms` bounds the whole run (absent means wait indefinitely);
/// hitting it, or cancelling the calling task, kills and releases the
/// terminal exactly once before raising.
///
/// # Example
/// ```mbt check
/// async test "terminal run returns exit code and output" {
///   let context = @acp.agent_context(
///     request_broker=request => {
///       match request {
///         TerminalCreate(_) =>
///           Ok(AgentReplyTerminalCreate({ terminal_id: "t1", meta: Omitted, }))
///         TerminalOutput(_) => {
///           let exit : @acp.ProtocolNullable[@acp.TerminalExitStatus] = Value({
///             exit_code: Value(0UL),
///             signal: Null,
///             meta: Omitted,
///           })
///           Ok(
///             AgentReplyTerminalOutput({
///               output: "done",
///               truncated: false,
///               exit_status: exit,
///               meta: Omitted,
///             }),
///           )
///         }
///         TerminalWaitForExit(_) =>
///           Ok(
///             AgentReplyTerminalWaitForExit({
///               exit_code: Value(0UL),
///               signal: Null,
///               meta: Omitted,
///             }),
///           )
///         TerminalRelease(_) => Ok(AgentReplyTerminalRelease({ meta: Omitted, }))
///         _ => Err(AgentContextBrokerFailure(method_name="unexpected"))
///       }
///     },
///     notification_broker=_ => Ok(()),
///   )
///   let terminal = AcpTerminal::AcpTerminal(context~, session_id="s1")
///   let chunks : Array[String] = []
///   let emit = (chunk : String) => chunks.push(chunk)
///   let result = terminal.run("make check", cwd="/repo", on_output=emit)
///   assert_eq(result.exit_code, Some(0))
///   assert_eq(result.output, "done")
///   assert_eq(chunks.length(), 1)
/// }
/// ```
pub async fn AcpTerminal::run(
  self : AcpTerminal,
  command : String,
  cwd~ : String,
  on_output? : (String) -> Unit,
  timeout_ms? : Int,
) -> AcpTerminalResult raise AcpTerminalError {
  let create_params : @acp.TerminalCreateParams = {
    session_id: self.session_id,
    command,
    args: Omitted,
    env: Omitted,
    cwd: Value(cwd),
    output_byte_limit: Omitted,
    meta: Omitted,
  }
  match terminal_create_call(self.context, create_params) {
    Err(failure) => raise terminal_error(failure)
    Ok(created) => {
      let terminal_id = created.terminal_id
      match
        terminal_drive(
          self.context,
          self.session_id,
          terminal_id,
          on_output,
          timeout_ms,
        ) {
        Ok(exit_run) => {
          // Success path: the command exited, release alone suffices.
          let release_params : @acp.TerminalReleaseParams = {
            session_id: self.session_id,
            terminal_id,
            meta: Omitted,
          }
          match
            terminal_release_call(self.context, release_params, exit_run.output) {
            Err(failure) => raise terminal_error(failure)
            Ok(_) => { exit_code: exit_run.exit_code, output: exit_run.output, }
          }
        }
        Err(failure) => {
          terminal_cleanup(self.context, self.session_id, terminal_id) catch {
            _ => ()
          }
          raise terminal_error(failure)
        }
      }
    }
  }
}
