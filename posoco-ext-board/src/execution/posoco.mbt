///|
/// Opt-in dedicated Agent driver. The factory supplies fresh host extensions;
/// this adapter constructs and exclusively owns the Agent and always inserts
/// its own scope observer/model gate first. Never pass shared execution owners
/// or lifecycle extensions that launch unrelated work into this factory.
pub struct PosocoBoardExecutionAdapter {
  priv extensions : () -> Array[&@posoco.Extension]
  priv config : @posoco.AgentConfig
  priv available : () -> Bool
  priv result_channel : BoardExecutionResultChannel?
  priv mut active : Bool
}

///|
/// No network credentials or tools are supplied implicitly.
///
/// ```mbt check
/// test {
///   let driver = @execution.PosocoBoardExecutionAdapter(extensions=() => [], available=() => {
///     false
///   })
///   assert_false(driver.ready())
/// }
/// ```
pub fn PosocoBoardExecutionAdapter::PosocoBoardExecutionAdapter(
  extensions~ : () -> Array[&@posoco.Extension],
  config~ : @posoco.AgentConfig = @posoco.agent_config(),
  available~ : () -> Bool = () => true,
  result_channel? : BoardExecutionResultChannel,
) -> PosocoBoardExecutionAdapter {
  { extensions, config, available, result_channel, active: false, }
}

///|
priv struct ExecutionGate {
  request : BoardExecutionRequest
  start : async (BoardExecutionRun) -> Bool
  mut scope : BoardExecutionRun?
  mut admitted : Bool
  mut failed : Bool
  mut completed : Bool
}

///|
impl @posoco.Observer for ExecutionGate with fn on_event(self, scope, event) {
  match (scope, event) {
    (Some(scope), TurnStarted) => {
      let run : BoardExecutionRun = {
        session_id: scope.session_id.to_string(),
        run_id: scope.run_id.to_string(),
        turn_id: scope.turn_id.to_string(),
      }
      if run.session_id != self.request.session_id ||
        (self.scope is Some(previous) && previous != run) {
        self.failed = true
      } else {
        self.scope = Some(run)
      }
    }
    (Some(scope), TurnCompleted) =>
      if self.scope is Some(run) &&
        scope.run_id.to_string() == run.run_id &&
        scope.turn_id.to_string() == run.turn_id &&
        scope.session_id.to_string() == run.session_id {
        self.completed = true
      }
    (_, TurnFailed(_)) => self.failed = true
    _ => ()
  }
}

///|
impl @posoco.PipelineHook for ExecutionGate with fn before_model(self, messages) {
  if self.failed {
    raise @posoco.HookAbort::Aborted(reason="execution scope unavailable")
  }
  if !self.admitted {
    let scope = match self.scope {
      Some(scope) => scope
      None =>
        raise @posoco.HookAbort::Aborted(reason="execution scope unavailable")
    }
    let admitted = (self.start)(scope) catch { _ => false }
    if !admitted {
      self.failed = true
      raise @posoco.HookAbort::Aborted(
        reason="execution admission not confirmed",
      )
    }
    self.admitted = true
  }
  messages
}

///|
pub extend PosocoBoardExecutionAdapter with BoardExecutionAdapter::{ready, run}

///|
pub impl BoardExecutionAdapter for PosocoBoardExecutionAdapter with fn ready(
  self,
) {
  let channel_available = match self.result_channel {
    Some(channel) => channel.available()
    None => true
  }
  !self.active && (self.available)() && channel_available
}

///|
pub impl BoardExecutionAdapter for PosocoBoardExecutionAdapter with fn run(
  self,
  request,
  start,
) {
  if !self.ready() {
    return Failed
  }
  self.active = true
  defer {
    self.active = false
  }
  let gate : ExecutionGate = {
    request,
    start,
    scope: None,
    admitted: false,
    failed: false,
    completed: false,
  }
  let exts : Array[&@posoco.Extension] = [gate, ..(self.extensions)()]
  let agent = @posoco.Agent::Agent(exts~, config=self.config)
  let result = agent.run_scoped(agent => {
    agent.run_turn(
      @kernel.UserMessage(content=[@kernel.Text(request.input)]),
      request.session_id,
    )
  }) catch {
    @posoco.AgentError::Cancelled(_) => return Cancelled
    _ => return if gate.completed { Interrupted } else { Failed }
  }
  if gate.admitted &&
    gate.completed &&
    !gate.failed &&
    result.final_session_id == request.session_id {
    if self.result_channel is Some(channel) {
      guard gate.scope is Some(run) else { return Interrupted }
      // A completed Agent turn stays Completed even when its bounded
      // ephemeral output cannot be captured (oversized text or a channel
      // already holding unread output). The channel simply stays empty:
      // the planning consumer observes a missing result instead of the
      // execution lying about a failed turn.
      ignore(channel.capture(request, run, result))
    }
    Completed
  } else {
    Interrupted
  }
}
