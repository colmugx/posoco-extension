///|
/// Bounded sanitized telemetry history and synchronous per-client fanout.
pub struct BoardEventHub {
  capacity : Int
  client_queue_depth : Int
  mut next_seq : Int64
  history_ : Array[@protocol.BoardWireEvent]
  clients : Array[BoardSubscription]
}

///|
pub struct BoardSubscription {
  initial_frames : Array[@protocol.BoardServerFrame]
  mailbox : @async.Queue[@protocol.BoardServerFrame]
  overflow : @async.Queue[Unit]
  mut dirty_seq : Int64?
  mut closed : Bool
}

///|
pub fn BoardEventHub::BoardEventHub(
  capacity? : Int = 4096,
  client_queue_depth? : Int = 256,
) -> BoardEventHub {
  if capacity <= 0 || client_queue_depth <= 0 {
    abort("board event hub capacities must be positive")
  }
  { capacity, client_queue_depth, next_seq: 1L, history_: [], clients: [], }
}

///|
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
  for client in self.clients {
    client.enqueue(@protocol.Event(event), event.seq)
  }
  event
}

///|
fn BoardSubscription::enqueue(
  self : BoardSubscription,
  frame : @protocol.BoardServerFrame,
  current_seq : Int64,
) -> Unit {
  if self.closed {
    return
  }
  if self.dirty_seq is Some(_) {
    self.dirty_seq = Some(current_seq)
    return
  }
  let accepted = self.mailbox.try_put(frame) catch { _ => false }
  if !accepted {
    self.dirty_seq = Some(current_seq)
    self.mailbox.close(clear=true)
    let _ = self.overflow.try_put(()) catch { _ => false }
  }
}

///|
/// Bootstrap and registration have no suspension point. Initial replay does
/// not consume mailbox capacity; subsequent publishes only enter the mailbox.
pub fn BoardEventHub::subscribe(
  self : BoardEventHub,
  last_seq : Int64,
) -> BoardSubscription {
  let current = self.current_seq()
  let initial_frames : Array[@protocol.BoardServerFrame] = if last_seq ==
    current {
    []
  } else if last_seq > 0L &&
    last_seq < current &&
    self.history_.length() > 0 &&
    last_seq >= self.history_[0].seq - 1L {
    self.history_since(last_seq).map(event => @protocol.Event(event))
  } else {
    [
      @protocol.Snapshot({
        protocol_version: @protocol.protocol_version(),
        last_seq: current,
        board_revision: 0L,
        payload: { "events": self.history_.map(event => event.to_json()) },
      }),
    ]
  }
  let client : BoardSubscription = {
    initial_frames,
    mailbox: @async.Queue(kind=Blocking(self.client_queue_depth)),
    overflow: @async.Queue(kind=Blocking(1)),
    dirty_seq: None,
    closed: false,
  }
  self.clients.push(client)
  client
}

///|
pub fn BoardSubscription::initial(
  self : BoardSubscription,
) -> Array[@protocol.BoardServerFrame] {
  self.initial_frames.copy()
}

///|
pub fn BoardSubscription::resync_required(
  self : BoardSubscription,
) -> @protocol.BoardServerFrame? {
  self.dirty_seq.map(seq => {
    @protocol.ResyncRequired(reason="client_queue_overflow", current_seq=seq)
  })
}

///|
pub async fn BoardSubscription::next(
  self : BoardSubscription,
) -> @protocol.BoardServerFrame {
  if self.resync_required() is Some(frame) {
    return frame
  }
  let frame = self.mailbox.get() catch {
    error =>
      match self.resync_required() {
        Some(frame) => return frame
        None => raise error
      }
  }
  self.resync_required().unwrap_or(frame)
}

///|
pub fn BoardEventHub::unsubscribe(
  self : BoardEventHub,
  client : BoardSubscription,
) -> Unit {
  client.closed = true
  client.dirty_seq = None
  client.mailbox.close(clear=true)
  client.overflow.close(clear=true)
  for i, candidate in self.clients {
    if physical_equal(candidate, client) {
      let _ = self.clients.remove(i)
      break
    }
  }
}

///|
pub fn BoardEventHub::subscriber_count(self : BoardEventHub) -> Int {
  self.clients.length()
}

///|
pub fn BoardEventHub::current_seq(self : BoardEventHub) -> Int64 {
  self.next_seq - 1L
}

///|
pub fn BoardEventHub::history(
  self : BoardEventHub,
) -> Array[@protocol.BoardWireEvent] {
  self.history_.copy()
}

///|
pub fn BoardEventHub::history_since(
  self : BoardEventHub,
  after_seq : Int64,
) -> Array[@protocol.BoardWireEvent] {
  self.history_.filter(event => event.seq > after_seq)
}
