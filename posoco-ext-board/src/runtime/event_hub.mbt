///|
/// Pure in-memory telemetry history. S0 has no clients and no async pump: the
/// hub only mints transport sequence numbers and keeps a bounded replay ring.
pub struct BoardEventHub {
  capacity : Int
  mut next_seq : Int64
  history_ : Array[@protocol.BoardWireEvent]
}

///|
pub fn BoardEventHub::BoardEventHub(capacity? : Int = 4096) -> BoardEventHub {
  if capacity <= 0 {
    abort("board event hub capacity must be positive")
  }
  { capacity, next_seq: 1L, history_: [], }
}

///|
/// Publish display/runtime telemetry. The caller supplies the current durable
/// Board revision; the EventHub never advances domain revision itself.
pub fn BoardEventHub::publish(
  self : BoardEventHub,
  board_revision~ : Int64,
  kind~ : String,
  scope? : @protocol.BoardEventScope? = None,
  payload~ : Json,
) -> @protocol.BoardWireEvent {
  let event : @protocol.BoardWireEvent = {
    seq: self.next_seq,
    board_revision,
    kind,
    scope,
    payload,
  }
  self.next_seq = self.next_seq + 1L
  self.history_.push(event)
  while self.history_.length() > self.capacity {
    let _ = self.history_.remove(0)
  }
  event
}

///|
pub fn BoardEventHub::current_seq(self : BoardEventHub) -> Int64 {
  self.next_seq - 1L
}

///|
pub fn BoardEventHub::history(
  self : BoardEventHub,
) -> Array[@protocol.BoardWireEvent] {
  self.history_.map(fn(event) { event })
}

///|
pub fn BoardEventHub::history_since(
  self : BoardEventHub,
  after_seq : Int64,
) -> Array[@protocol.BoardWireEvent] {
  self.history_.filter(fn(event) { event.seq > after_seq })
}
