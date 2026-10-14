///|
pub(all) enum Action {
  Ready
  Call(id~ : Int32, name~ : String, arguments~ : Json)
  Diagnostic(level~ : String, content~ : String)
  Closing
} derive(Debug)

///|
pub extend Action with Debug::{to_repr}

///|
priv enum Phase {
  Handshaking
  Running
  Closing
  Terminated
} derive(Eq)

///|
pub struct HostSession {
  priv mut phase : Phase
  priv pending : Map[Int32, Unit]
  priv seen : Map[Int32, Unit]
  priv max_pending : Int32
  priv max_calls : Int32
  priv mut result : Outcome?
}

///|
pub fn HostSession::HostSession(
  max_pending~ : Int32 = 8,
  max_calls~ : Int32 = 128,
) -> HostSession {
  {
    phase: Handshaking,
    pending: Map([]),
    seen: Map([]),
    max_pending,
    max_calls,
    result: None,
  }
}

///|
pub fn HostSession::receive(
  self : HostSession,
  message : Message,
) -> Action raise ProtocolError {
  match (self.phase, message) {
    (Handshaking, Hello(protocol~)) if protocol == version => {
      self.phase = Running
      Ready
    }
    (Running, Request(id~, name~, arguments~)) => {
      if id <= 0 || name == "" {
        raise Invalid("invalid request identity")
      }
      if self.seen.contains(id) {
        raise Invalid("duplicate request id")
      }
      if self.pending.length() >= self.max_pending {
        raise Invalid("pending request limit exceeded")
      }
      if self.seen.length() >= self.max_calls {
        raise Invalid("child call budget exceeded")
      }
      self.seen[id] = ()
      self.pending[id] = ()
      Call(id~, name~, arguments~)
    }
    (Running, Log(level~, content~)) => Diagnostic(level~, content~)
    (Running, Result(outcome~)) => {
      if !self.pending.is_empty() {
        raise Invalid("final result while requests are pending")
      }
      self.result = Some(outcome)
      self.phase = Phase::Closing
      Action::Closing
    }
    _ => raise Invalid("message is illegal in the current protocol state")
  }
}

///|
pub fn HostSession::reply(
  self : HostSession,
  id : Int32,
  outcome : Outcome,
) -> Message raise ProtocolError {
  if self.phase != Running {
    raise Invalid("reply after scope closed")
  }
  if !self.pending.contains(id) {
    raise Invalid("unknown or already settled request id")
  }
  self.pending.remove(id)
  Reply(id~, outcome~)
}

///|
pub fn HostSession::finish(
  self : HostSession,
  exit_code : Int32,
) -> Outcome raise ProtocolError {
  if self.phase != Phase::Closing {
    raise Invalid("guest exited without a final result")
  }
  self.phase = Terminated
  if exit_code != 0 {
    raise Invalid("guest exited with nonzero status: " + exit_code.to_string())
  }
  match self.result {
    Some(result) => result
    None => raise Invalid("guest exited without a final result")
  }
}

///|
pub fn HostSession::close(self : HostSession) -> Unit {
  self.phase = Terminated
  self.pending.clear()
}
