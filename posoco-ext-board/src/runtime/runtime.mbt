///|
/// Minimal S0 facade. It owns no Board domain state, no worker, no server and
/// no Agent reference; only the process-local telemetry EventHub exists here.
pub struct BoardRuntime {
  hub : BoardEventHub
}

///|
pub fn BoardRuntime::BoardRuntime(event_buffer? : Int = 4096) -> BoardRuntime {
  { hub: BoardEventHub::BoardEventHub(capacity=event_buffer), }
}

///|
pub fn BoardRuntime::publish_telemetry(
  self : BoardRuntime,
  board_revision~ : Int64,
  kind~ : String,
  scope? : @protocol.BoardEventScope? = None,
  payload~ : Json,
) -> @protocol.BoardWireEvent {
  self.hub.publish(board_revision~, kind~, scope~, payload~)
}

///|
pub fn BoardRuntime::event_history(
  self : BoardRuntime,
) -> Array[@protocol.BoardWireEvent] {
  self.hub.history()
}

///|
pub fn BoardRuntime::current_seq(self : BoardRuntime) -> Int64 {
  self.hub.current_seq()
}
