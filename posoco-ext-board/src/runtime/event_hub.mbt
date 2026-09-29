///|
/// Per-WebSocket outbound mailbox. Queue writes are synchronous/non-blocking so
/// Observer callbacks can publish telemetry without awaiting socket I/O.
pub struct BoardClientMailbox {
  id : Int
  queue : @aqueue.Queue[@protocol.BoardServerFrame]
  depth : Int
  mut pending : Int
  mut dirty : Bool
  mut dirty_seq : Int64
  mut closed : Bool
}

///|
fn BoardClientMailbox::BoardClientMailbox(
  id~ : Int,
  depth~ : Int,
) -> BoardClientMailbox {
  {
    id,
    queue: @aqueue.Queue(kind=DiscardOldest(depth)),
    depth,
    pending: 0,
    dirty: false,
    dirty_seq: 0L,
    closed: false,
  }
}

///|
/// Enqueue one live event. If DiscardOldest must evict, mark this mailbox
/// dirty. The send pump will emit resync_required before any more event frame
/// and close the connection; silent event loss is never allowed.
fn BoardClientMailbox::enqueue_event(
  self : BoardClientMailbox,
  event : @protocol.BoardWireEvent,
) -> Unit {
  if self.closed {
    return
  }
  if self.pending >= self.depth {
    self.dirty = true
    self.dirty_seq = event.seq
  } else {
    self.pending += 1
  }
  ignore(
    self.queue.try_put(@protocol.BoardServerFrame::Event(event)) catch {
      _ => false
    },
  )
}

///|
/// Wait for the next outbound frame. A previously detected queue overwrite
/// takes precedence over queued telemetry and forces an explicit resync.
pub async fn BoardClientMailbox::next_frame(
  self : BoardClientMailbox,
) -> @protocol.BoardServerFrame? noraise {
  if self.closed {
    return None
  }
  let frame = self.queue.get() catch { _ => return None }
  if self.pending > 0 {
    self.pending -= 1
  }
  if self.dirty {
    self.dirty = false
    Some(
      @protocol.BoardServerFrame::ResyncRequired({
        reason: "client_queue_overflow",
        current_seq: self.dirty_seq,
      }),
    )
  } else {
    Some(frame)
  }
}

///|
pub fn BoardClientMailbox::close(self : BoardClientMailbox) -> Unit {
  if !self.closed {
    self.closed = true
    self.queue.close(clear=true)
  }
}

///|
pub fn BoardClientMailbox::client_id(self : BoardClientMailbox) -> Int {
  self.id
}

///|
/// Process-local telemetry history and live subscriber fanout. Domain revision
/// remains caller-owned; this hub mints only transport sequence numbers.
pub struct BoardEventHub {
  capacity : Int
  client_queue_depth : Int
  mut next_seq : Int64
  mut next_client_id : Int
  history_ : Array[@protocol.BoardWireEvent]
  clients : Array[BoardClientMailbox]
}

///|
pub fn BoardEventHub::BoardEventHub(
  capacity? : Int = 4096,
  client_queue_depth? : Int = 256,
) -> BoardEventHub {
  if capacity <= 0 {
    abort("board event hub capacity must be positive")
  }
  if client_queue_depth <= 0 {
    abort("board client queue depth must be positive")
  }
  {
    capacity,
    client_queue_depth,
    next_seq: 1L,
    next_client_id: 1,
    history_: [],
    clients: [],
  }
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
  self.next_seq += 1L
  self.history_.push(event)
  while self.history_.length() > self.capacity {
    let _ = self.history_.remove(0)
  }
  for client in self.clients {
    client.enqueue_event(event)
  }
  event
}

///|
pub fn BoardEventHub::current_seq(self : BoardEventHub) -> Int64 {
  self.next_seq - 1L
}

///|
pub fn BoardEventHub::current_board_revision(self : BoardEventHub) -> Int64 {
  if self.history_.is_empty() {
    0L
  } else {
    self.history_[self.history_.length() - 1].board_revision
  }
}

///|
pub fn BoardEventHub::history(self : BoardEventHub) -> Array[
  @protocol.BoardWireEvent,
] {
  self.history_.map(fn(event) { event })
}

///|
pub fn BoardEventHub::history_since(
  self : BoardEventHub,
  after_seq : Int64,
) -> Array[@protocol.BoardWireEvent] {
  self.history_.filter(fn(event) { event.seq > after_seq })
}

///|
fn BoardEventHub::snapshot(self : BoardEventHub) -> @protocol.BoardSnapshot {
  @protocol.BoardSnapshot::{
    protocol_version: @protocol.protocol_version(),
    last_seq: self.current_seq(),
    board_revision: self.current_board_revision(),
    payload: Json::object({
      "events": Json::array(self.history_.map(fn(event) { event.to_json() })),
    }),
  }
}

///|
/// Build the initial reconnect response for one hello frame.
///
/// - new clients and sequence gaps receive a snapshot;
/// - covered ranges receive ordered replay events;
/// - a client already at current_seq receives no duplicate frame.
pub fn BoardEventHub::sync_frames(
  self : BoardEventHub,
  last_seq : Int64,
) -> Array[@protocol.BoardServerFrame] {
  let current = self.current_seq()
  if last_seq <= 0L || last_seq > current {
    return [@protocol.BoardServerFrame::Snapshot(self.snapshot())]
  }
  if current == last_seq {
    return []
  }
  if self.history_.is_empty() {
    return [@protocol.BoardServerFrame::Snapshot(self.snapshot())]
  }
  let oldest = self.history_[0].seq
  if last_seq < oldest - 1L {
    [@protocol.BoardServerFrame::Snapshot(self.snapshot())]
  } else {
    self.history_since(last_seq).map(fn(event) {
      @protocol.BoardServerFrame::Event(event)
    })
  }
}

///|
/// Register a live client before computing its hello replay. This may create a
/// duplicate event at the replay/live boundary, but never a gap; clients
/// de-duplicate by seq.
pub fn BoardEventHub::register_client(self : BoardEventHub) -> BoardClientMailbox {
  let mailbox = BoardClientMailbox::BoardClientMailbox(
    id=self.next_client_id,
    depth=self.client_queue_depth,
  )
  self.next_client_id += 1
  self.clients.push(mailbox)
  mailbox
}

///|
pub fn BoardEventHub::unregister_client(
  self : BoardEventHub,
  client_id : Int,
) -> Unit {
  let mut index = 0
  while index < self.clients.length() {
    if self.clients[index].client_id() == client_id {
      let mailbox = self.clients.remove(index)
      mailbox.close()
      return
    }
    index += 1
  }
}

///|
pub fn BoardEventHub::client_count(self : BoardEventHub) -> Int {
  self.clients.length()
}
