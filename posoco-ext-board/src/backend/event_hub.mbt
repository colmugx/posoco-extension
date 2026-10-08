///|
/// Detached copy of a JSON tree. Mutable `Object` maps and `Array` items are
/// duplicated, so no reader can ever reach into retained backend state.
fn board_json_detached(value : Json) -> Json {
  match value {
    Json::Array(items) => Json::array(items.map(board_json_detached))
    Json::Object(fields) => {
      let copy : Map[String, Json] = Map::from_array([])
      for key, item in fields {
        copy[key] = board_json_detached(item)
      }
      Json::object(copy)
    }
    other => other
  }
}

///|
fn board_scope_detached(
  scope : @protocol.BoardEventScope,
) -> @protocol.BoardEventScope {
  {
    session_id: scope.session_id,
    run_id: scope.run_id,
    turn_id: scope.turn_id,
  }
}

///|
fn board_event_detached(
  event : @protocol.BoardWireEvent,
) -> @protocol.BoardWireEvent {
  {
    seq: event.seq,
    board_revision: event.board_revision,
    kind: event.kind,
    scope: event.scope.map(board_scope_detached),
    payload: board_json_detached(event.payload),
  }
}

///|
fn board_snapshot_detached(
  snapshot : @protocol.BoardSnapshot,
) -> @protocol.BoardSnapshot {
  {
    protocol_version: snapshot.protocol_version,
    last_seq: snapshot.last_seq,
    board_revision: snapshot.board_revision,
    payload: board_json_detached(snapshot.payload),
  }
}

///|
fn board_frame_detached(
  frame : @protocol.BoardServerFrame,
) -> @protocol.BoardServerFrame {
  match frame {
    @protocol.Event(event) => @protocol.Event(board_event_detached(event))
    @protocol.Snapshot(snapshot) =>
      @protocol.Snapshot(board_snapshot_detached(snapshot))
    other => other
  }
}

///|
/// Bounded sanitized telemetry history and synchronous per-client fanout.
/// The hub is backend-owned: adapters only ever see detached events,
/// explicit subscriptions and integer cursors.
priv struct BoardEventHub {
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
  priv mut initial_frames : Array[@protocol.BoardServerFrame]
  /// Bootstrap boundary: events at or before it were already covered by the
  /// installed snapshot, so the sender drops their stale mailbox copies.
  priv mut baseline_seq : Int64
  priv mailbox : @async.Queue[@protocol.BoardServerFrame]
  priv overflow : @async.Queue[Unit]
  priv mut dirty_seq : Int64?
  priv mut closed : Bool
}

///|
fn BoardEventHub::BoardEventHub(
  capacity? : Int = 4096,
  client_queue_depth? : Int = 256,
) -> BoardEventHub {
  if capacity <= 0 || client_queue_depth <= 0 {
    abort("board event hub capacities must be positive")
  }
  { capacity, client_queue_depth, next_seq: 1L, history_: [], clients: [], }
}

///|
fn BoardEventHub::publish(
  self : BoardEventHub,
  board_revision~ : Int64,
  kind~ : String,
  scope? : @protocol.BoardEventScope? = None,
  payload~ : Json,
) -> @protocol.BoardWireEvent {
  // The publisher keeps its payload; the retained event and every fanout
  // copy are detached from it.
  let event : @protocol.BoardWireEvent = board_event_detached({
    seq: self.next_seq,
    board_revision,
    kind,
    scope,
    payload,
  })
  self.next_seq = self.next_seq + 1L
  self.history_.push(event)
  while self.history_.length() > self.capacity {
    let _ = self.history_.remove(0)
  }
  for client in self.clients {
    client.enqueue(@protocol.Event(event), event.seq)
  }
  board_event_detached(event)
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
/// fulfilled by the caller — the backend builds the authoritative composite
/// through the coordinator and installs it with `install_snapshot`.
fn BoardEventHub::subscribe(
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
  self.initial_frames = [@protocol.Snapshot(board_snapshot_detached(frame))]
}

///|
pub fn BoardSubscription::initial(
  self : BoardSubscription,
) -> Array[@protocol.BoardServerFrame] {
  self.initial_frames.map(board_frame_detached)
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
      return board_frame_detached(frame)
    }
  }
}

///|
fn BoardEventHub::unsubscribe(
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
fn BoardEventHub::subscriber_count(self : BoardEventHub) -> Int {
  self.clients.length()
}

///|
fn BoardEventHub::current_seq(self : BoardEventHub) -> Int64 {
  self.next_seq - 1L
}

///|
fn BoardEventHub::history(
  self : BoardEventHub,
) -> Array[@protocol.BoardWireEvent] {
  self.history_.map(board_event_detached)
}

///|
fn BoardEventHub::history_since(
  self : BoardEventHub,
  after_seq : Int64,
) -> Array[@protocol.BoardWireEvent] {
  self.history_.filter(event => event.seq > after_seq).map(board_event_detached)
}

///|
/// Retained events up to and including `through_seq`: the contiguous
/// retained tail a composite bootstrap extends with the live frames after
/// its stream boundary.
fn BoardEventHub::history_through(
  self : BoardEventHub,
  through_seq : Int64,
) -> Array[@protocol.BoardWireEvent] {
  self.history_
  .filter(event => event.seq <= through_seq)
  .map(board_event_detached)
}

///|
/// One application writer. The overflow watcher cancels and joins an
/// in-flight send before teardown, including while a large bootstrap is
/// being written.
#warnings("-unused_value")
pub async fn BoardSubscription::pump(
  self : BoardSubscription,
  send : async (@protocol.BoardServerFrame) -> Unit,
) -> Unit {
  let mut writing = false
  @async.any([
    () => {
      for frame in self.initial_frames {
        if self.dirty_seq is Some(_) {
          return
        }
        writing = true
        send(board_frame_detached(frame))
        writing = false
      }
      for ;; {
        let frame = self.next()
        if self.dirty_seq is Some(_) {
          return
        }
        writing = true
        send(frame)
        writing = false
      }
    },
    () => self.overflow.get(),
  ])
  // A cancelled fragmented WebSocket write cannot safely start another
  // message. In that case close immediately; otherwise resync is best effort.
  if !writing {
    if self.resync_required() is Some(frame) {
      @async.with_timeout(1000, () => send(frame)) catch {
        _ => ()
      }
    }
  }
}
