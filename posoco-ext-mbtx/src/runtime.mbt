///|
pub using @protocol {type Outcome}

///|
pub suberror RuntimeError {
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
pub struct Artifact {
  priv path : String
  priv workspace : String
  priv key : String
}

///|
pub fn Artifact::identity(self : Artifact) -> String {
  let parts = self.workspace.split("/").to_array()
  parts[parts.length() - 1].to_owned()
}

///|
pub struct Runtime {
  priv sdk_source_root : String
  priv async_source_root : String
  priv moon : String
  priv moonrun : String
  priv cache : Map[String, Artifact]
  priv build_lock : @async.Mutex
  priv active : Map[String, () -> Unit]
  priv mut closed : Bool
  priv mut clearing : Bool
}

///|
pub fn Runtime::Runtime(
  sdk_source_root~ : String,
  async_source_root~ : String,
  moon~ : String = "moon",
  moonrun~ : String = "moonrun",
) -> Runtime {
  {
    sdk_source_root,
    async_source_root,
    moon,
    moonrun,
    cache: Map([]),
    build_lock: @async.Mutex(),
    active: Map([]),
    closed: false,
    clearing: false,
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
pub async fn Runtime::clear_cache(self : Runtime) -> Unit {
  self.build_lock.acquire()
  defer self.build_lock.release()
  if !self.active.is_empty() {
    raise RuntimeError::Invalid(
      "cannot clear artifacts while invocations are active",
    )
  }
  self.clearing = true
  defer {
    self.clearing = false
  }
  errdefer {
    self.closed = true
  }
  for key, artifact in self.cache.copy() {
    remove_directory(artifact.workspace)
    self.cache.remove(key)
  }
}

///|
pub async fn Runtime::close(self : Runtime) -> Unit {
  if !self.active.is_empty() {
    raise RuntimeError::Invalid(
      "cancel and join active invocations before closing runtime",
    )
  }
  self.closed = true
  self.clear_cache()
}
