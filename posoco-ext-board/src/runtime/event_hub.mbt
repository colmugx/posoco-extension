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
/// Explicit synchronous bootstrap plan computed atomically with
/// registration. The hub never fabricates a snapshot: a cursor that
/// retained history cannot serve plans `SnapshotRequired`, and the caller
/// decides where the authoritative snapshot comes from.
pub(all) enum BoardSubscriptionPlan {
  /// The cursor equals the current stream head — including the empty `0/0`
  /// case — so only live frames follow.
  Live
  /// Retained history covers the whole missing interval; the carried
  /// events are the contiguous retained suffix after the cursor.
  Replay(Array[@protocol.BoardWireEvent])
  /// The cursor is zero while events exist, older than the retained
  /// history, inside a gap, or ahead of the head: an authoritative
  /// snapshot is required before any frame is sent.
  SnapshotRequired
} derive(Eq, Debug)

///|
pub extend BoardSubscriptionPlan with Eq::{equal, not_equal}

///|
pub extend BoardSubscriptionPlan with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub struct BoardSubscription {
  /// Bootstrap plan computed atomically with registration.
  plan : BoardSubscriptionPlan
  mut initial_frames : Array[@protocol.BoardServerFrame]
  /// Bootstrap boundary: events at or before it were already covered by the
  /// installed snapshot, so the sender drops their stale mailbox copies.
  mut baseline_seq : Int64
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
/// Registration computes the explicit bootstrap plan atomically: there is
/// no suspension point, initial replay does not consume mailbox capacity
/// and no snapshot is ever fabricated here. A `SnapshotRequired` plan is
/// fulfilled by the caller — the runtime builds the authoritative composite
/// through the coordinator and installs it with `install_snapshot`.
pub fn BoardEventHub::subscribe(
  self : BoardEventHub,
  last_seq : Int64,
  has_board_snapshot : Bool,
) -> BoardSubscription {
  let current = self.current_seq()
  let mut initial_frames : Array[@protocol.BoardServerFrame] = []
  let plan : BoardSubscriptionPlan = if !has_board_snapshot {
    SnapshotRequired
  } else if last_seq == current {
    Live
  } else if last_seq > 0L &&
    last_seq < current &&
    self.history_.length() > 0 &&
    last_seq >= self.history_[0].seq - 1L {
    let replay = self.history_since(last_seq)
    initial_frames = replay.map(event => @protocol.Event(event))
    Replay(replay)
  } else {
    SnapshotRequired
  }
  let client : BoardSubscription = {
    plan,
    initial_frames,
    baseline_seq: last_seq,
    mailbox: @async.Queue(kind=Blocking(self.client_queue_depth)),
    overflow: @async.Queue(kind=Blocking(1)),
    dirty_seq: None,
    closed: false,
  }
  self.clients.push(client)
  client
}

///|
/// Install the authoritative bootstrap frame of a `SnapshotRequired`
/// subscription. Everything at or before `frame.last_seq` is already part
/// of the snapshot, so the sender skips those stale mailbox copies instead
/// of delivering duplicates.
pub fn BoardSubscription::install_snapshot(
  self : BoardSubscription,
  frame : @protocol.BoardSnapshot,
) -> Unit {
  self.baseline_seq = frame.last_seq
  self.initial_frames = [@protocol.Snapshot(frame)]
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
/// Events at or before the installed bootstrap boundary were already part
/// of the snapshot frame; the subscription drops their stale mailbox
/// copies. Command results and resync markers are never sequenced and
/// always pass.
fn board_stale_frame(
  client : BoardSubscription,
  frame : @protocol.BoardServerFrame,
) -> Bool {
  match frame {
    @protocol.Event(event) => event.seq <= client.baseline_seq
    _ => false
  }
}

///|
pub async fn BoardSubscription::next(
  self : BoardSubscription,
) -> @protocol.BoardServerFrame {
  for ;; {
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
    let frame = self.resync_required().unwrap_or(frame)
    if !board_stale_frame(self, frame) {
      return frame
    }
  }
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

///|
/// Retained events up to and including `through_seq`: the contiguous
/// retained tail a composite bootstrap extends with the live frames after
/// its stream boundary.
pub fn BoardEventHub::history_through(
  self : BoardEventHub,
  through_seq : Int64,
) -> Array[@protocol.BoardWireEvent] {
  self.history_.filter(event => event.seq <= through_seq)
}
