///|
pub using @protocol {type Outcome}

///|
/// Implemented by the guest transport or a test double, never a raw host provider.
pub(open) trait ToolClient {
  async fn call(Self, name : String, arguments : Json) -> Outcome
}

///|
pub(open) trait LogSink {
  async fn log(Self, level : String, content : String) -> Unit
}

///|
pub struct Context {
  priv tools : &ToolClient
  priv allowed : Array[String]
  priv logs : &LogSink?
  priv mut closed : Bool
}

///|
pub fn Context::Context(
  tools~ : &ToolClient,
  allowed~ : Array[String],
  logs? : &LogSink,
) -> Context {
  { tools, allowed: allowed.copy(), logs, closed: false, }
}

///|
pub async fn Context::call(
  self : Context,
  name : String,
  arguments : Json,
) -> Outcome {
  if self.closed {
    return @protocol.Failure(
      code="ScopeClosed",
      content="invocation scope is closed",
      structured=None,
    )
  }
  if !self.allowed.contains(name) {
    return @protocol.Failure(
      code="CapabilityDenied",
      content="tool is outside the effective capability: " + name,
      structured=None,
    )
  }
  self.tools.call(name, arguments)
}

///|
pub async fn Context::log(
  self : Context,
  level : String,
  content : String,
) -> Unit {
  if self.closed {
    raise Failure::Failure("invocation scope is closed")
  }
  match self.logs {
    Some(logs) => logs.log(level, content)
    None => ()
  }
}

///|
pub fn Context::close(self : Context) -> Unit {
  self.closed = true
}
