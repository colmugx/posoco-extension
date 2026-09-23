///|
/// Event bridge attached to one child run (design §3.3): projects child
/// `TurnEvent`s onto the extension's subscription channel as tagged
/// `SubagentEvent`s and accumulates the run's cost attribution (design §3.4)
/// — turn count from `TurnCompleted`, token usage from every
/// `ModelResponseReceived`. Created per spawn; its counters are read after
/// the child run ends to build the usage footer.
priv struct BridgeObserver {
  child_session : String
  kind : String
  callbacks : Array[(@kit.SubagentEvent) -> Unit]
  mut turns : Int
  mut input_tokens : Int
  mut output_tokens : Int
}

///|
fn BridgeObserver::BridgeObserver(
  child_session~ : String,
  kind~ : String,
  callbacks~ : Array[(@kit.SubagentEvent) -> Unit],
) -> BridgeObserver {
  {
    child_session,
    kind,
    callbacks,
    turns: 0,
    input_tokens: 0,
    output_tokens: 0,
  }
}

///|
fn BridgeObserver::handle(
  self : BridgeObserver,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    TurnCompleted => self.turns = self.turns + 1
    ModelResponseReceived(usage~, ..) =>
      match usage {
        Some(u) => {
          match u.input_tokens {
            Some(n) => self.input_tokens = self.input_tokens + n
            None => ()
          }
          match u.output_tokens {
            Some(n) => self.output_tokens = self.output_tokens + n
            None => ()
          }
        }
        None => ()
      }
    _ => ()
  }
  let tagged : @kit.SubagentEvent = {
    child_session: self.child_session,
    kind: self.kind,
    event,
  }
  for callback in self.callbacks {
    callback(tagged)
  }
}

///|
impl @posoco.Observer for BridgeObserver with fn on_event(
  self : BridgeObserver,
  event : @posoco.TurnEvent,
) -> Unit {
  self.handle(event)
}

///|
/// The kernel dispatches only the scoped variant; the unscoped override is
/// kept explicit so both entry points route through the same handler.
impl @posoco.Observer for BridgeObserver with fn on_event_at(
  self : BridgeObserver,
  _scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  self.handle(event)
}
