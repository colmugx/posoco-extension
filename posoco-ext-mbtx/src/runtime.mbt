///|
pub using @protocol {type Outcome}

///|
pub suberror RuntimeError {
  ToolchainUnavailable(String)
  BuildFailed(String)
  ProtocolFailure(String)
  GuestFailure(String)
  TimedOut(String)
  Cancelled
  Closed
  Invalid(String)
} derive(Debug)

///|
pub extend RuntimeError with Debug::{to_repr}

///|
/// Reserved for the future Posoco-scoped adapter. This port does not implement governance.
pub(open) trait ToolInvoker {
  async fn invoke(Self, name : String, arguments : Json) -> Outcome
}

///|
pub(all) struct Diagnostic {
  level : String
  content : String
} derive(Debug)

///|
pub extend Diagnostic with Debug::{to_repr}

///|
pub(all) struct InvocationResult {
  outcome : Outcome
  stderr : String
  logs : Array[Diagnostic]
}

///|
/// Auto prefers moonx; Moon uses build-only followed by a directly owned moonrun.
pub(all) enum Launcher {
  Auto
  Moon
  Moonx
} derive(Debug, Eq)

///|
pub extend Launcher with Debug::{to_repr}

///|
pub extend Launcher with Eq::{equal, not_equal}

///|
pub struct Runtime {
  priv launcher : Launcher
  priv moon : String
  priv moonx : String
  priv moonrun : String
  priv toolchain : ToolchainManager
  priv build_cache : String?
  priv build_lock : @async.Mutex
  priv active : Map[String, () -> Unit]
  priv mut closed : Bool
}

///|
pub fn Runtime::Runtime(
  launcher~ : Launcher = Auto,
  moon~ : String = "moon",
  moonx~ : String = "moonx",
  moonrun~ : String = "moonrun",
  bus? : @devkit.EventBus,
  home? : String,
  prefer_system~ : Bool = true,
  build_cache? : String,
) -> Runtime {
  {
    launcher,
    moon,
    moonx,
    moonrun,
    toolchain: ToolchainManager(bus?, home?, prefer_system~),
    build_cache,
    build_lock: @async.Mutex(),
    active: Map([]),
    closed: false,
  }
}

///|
pub fn Runtime::cancel(self : Runtime, invocation_id : String) -> Bool {
  match self.active.get(invocation_id) {
    Some(cancel) => {
      cancel()
      true
    }
    None => false
  }
}

///|
pub fn Runtime::close(self : Runtime) -> Unit raise RuntimeError {
  if !self.active.is_empty() {
    raise RuntimeError::Invalid(
      "cancel and join active invocations before closing runtime",
    )
  }
  self.closed = true
}

///|
/// Read-only diagnostics; querying never triggers a download.
pub fn Runtime::toolchain_status(self : Runtime) -> String {
  self.toolchain.status()
}

///|
/// The caller owns the lifetime and cleanup of this persistent compiler cache.
pub fn Runtime::build_cache_directory(self : Runtime) -> String? {
  self.build_cache
}
