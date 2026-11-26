///|
/// Session-scoped interval runner. It does not create an independent agent
/// loop: all executions pass through Agent::run_turn and its normal tool,
/// permission, session and cancellation governance.
pub struct LoopExtension {
  priv mut runtime : LoopRuntime?
  priv mut session_id : String?
  priv now_ms : () -> Int64
  priv sleep_ms : async (Int32) -> Unit
  priv trace : (String) -> Unit
  priv max_failures : Int32
}

///|
pub fn LoopExtension::LoopExtension(
  now_ms~ : () -> Int64 = fn() { @async.now() },
  sleep_ms~ : async (Int32) -> Unit = async fn(ms : Int32) { @async.sleep(ms) },
  trace~ : (String) -> Unit = fn(_ : String) { () },
  max_failures~ : Int32 = 3,
) -> LoopExtension {
  {
    runtime: None,
    session_id: None,
    now_ms,
    sleep_ms,
    trace,
    max_failures: if max_failures > 0 {
      max_failures
    } else {
      3
    },
  }
}

///|
/// Start once on the host-owned TaskGroup after composing the Agent. The
/// group's lifetime must cover the active Agent::run_scoped scope. Nothing
/// schedules until the host binds a session with set_session().
pub fn LoopExtension::start(
  self : LoopExtension,
  group~ : @async.TaskGroup,
  agent~ : @posoco.Agent,
) -> Unit {
  if self.runtime is Some(_) {
    return
  }
  let runtime = LoopRuntime::start(
    group~,
    now_ms=self.now_ms,
    sleep_ms=self.sleep_ms,
    trace=self.trace,
    max_failures=self.max_failures,
    bound_session=self.session_id,
    execute=async fn(session_id : String, prompt : String) -> DispatchResult {
      let input : @posoco.Message = @posoco.Message::UserMessage(content=[
        @posoco.Content::Text(prompt),
      ])
      let result : Result[@posoco.TurnResult, @posoco.AgentError] = Ok(
        agent.run_turn(input, session_id),
      ) catch {
        error => Err(error)
      }
      match result {
        Ok(_) => Done
        Err(@posoco.AgentError::Busy(..)) => Busy
        Err(error) => Error(error.to_string())
      }
    },
  )
  self.runtime = Some(runtime)
}

///|
/// Bind the session that is allowed to receive loop turns. The host must
/// mirror its own active-session changes and clear this on teardown.
/// Jobs from other sessions remain dormant and never change the binding.
pub fn LoopExtension::set_session(
  self : LoopExtension,
  session_id : String,
) -> Unit {
  self.session_id = if session_id == "" { None } else { Some(session_id) }
  match self.runtime {
    Some(runtime) => runtime.bind(self.session_id)
    None => ()
  }
}

///|
pub async fn LoopExtension::snapshot(self : LoopExtension) -> Array[LoopJob] {
  match self.runtime {
    Some(runtime) => runtime.jobs()
    None => []
  }
}

///|
/// Test and clock-driver seam; production ticks automatically.
pub async fn LoopExtension::poll(self : LoopExtension) -> Unit {
  match self.runtime {
    Some(runtime) => runtime.poll()
    None => ()
  }
}

///|
pub async fn LoopExtension::shutdown(self : LoopExtension) -> Unit {
  match self.runtime {
    Some(runtime) => {
      runtime.shutdown()
      self.runtime = None
    }
    None => ()
  }
}

///|
pub impl @posoco.Lifecycle for LoopExtension with fn on_shutdown(
  self : LoopExtension,
) -> Unit {
  self.shutdown()
}

///|
pub extend LoopExtension with @posoco.Lifecycle::{
  on_compose,
  on_start,
  on_shutdown,
}

///|
pub impl @posoco.Extension for LoopExtension with fn extension_id(
  _self : LoopExtension,
) -> String {
  "posoco_ext_loop"
}

///|
pub impl @posoco.Extension for LoopExtension with fn manifest(
  self : LoopExtension,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_loop", lifecycle=[self], commands=[
    self,
  ])
}

///|
pub extend LoopExtension with @posoco.Extension::{extension_id, manifest}

///|
/// Friendly constructor for host composition.
pub fn loop_extension() -> LoopExtension {
  LoopExtension()
}
