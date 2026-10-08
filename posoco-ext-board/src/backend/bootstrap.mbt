///|
/// S3C0 backend stream integration. The backend is the only place where
/// the durable coordinator and the telemetry hub meet: it installs a
/// synchronous `on_commit` hook that projects every committed domain event
/// into the owned hub, and it answers the coordinator's `stream_cursor`
/// with the live hub head, so every stream boundary is an actual hub
/// position. The hub never learns about the coordinator and the
/// coordinator never learns about the hub.

///|
/// Commit hook installed on the backend's coordinator: project every
/// committed event — kind, payload and committed revision, without scope —
/// and publish it into the owned hub synchronously before the committing
/// caller is answered. The hub mints the transport sequence; publishing
/// never awaits and never fails.
fn board_publish_commit(
  hub : BoardEventHub,
  snapshot : @domain.BoardStateSnapshot,
  events : Array[@domain.BoardEvent],
) -> Unit {
  if events.is_empty() {
    return
  }
  for event in events {
    let wire = @protocol.project_event(snapshot, event)
    let _ = hub.publish(
      board_revision=wire.board_revision,
      kind=wire.kind,
      payload=wire.payload,
    )
  }
}

///|
/// Bounded bootstrap attempts. Each attempt takes a fresh boundary, so a
/// burst that evicted the previous suffix converges instead of looping on
/// the same stale position.
let board_bootstrap_attempts : Int = 4

///|
/// Composite snapshot for the stream boundary the coordinator answered:
/// `last_seq` is exactly `stream.stream_seq` — never a later hub head — and
/// the events are every retained hub event up to and including that
/// boundary, ending exactly at it. `None` when the retained suffix ending
/// at the boundary was evicted (or the boundary is zero with retained
/// events): an invalid or fabricated snapshot is never composed; the
/// bootstrap retries with a fresher boundary instead.
fn BoardBackend::build_composite(
  self : BoardBackend,
  stream : @coordinator.BoardStreamSnapshot,
) -> @protocol.BoardSnapshot? {
  let cursor = stream.stream_seq
  let retained = self.hub.history_through(cursor)
  let complete = if cursor == 0L {
    retained.is_empty()
  } else {
    retained.length() > 0 && retained[retained.length() - 1].seq == cursor
  }
  if !complete {
    return None
  }
  Some({
    protocol_version: @protocol.protocol_version(),
    last_seq: cursor,
    board_revision: stream.board_snapshot.revision,
    payload: {
      "board": @protocol.snapshot_to_json(stream.board_snapshot),
      "events": retained.map(event => event.to_json()),
    },
  })
}

///|
/// Authoritative snapshot bootstrap. Awaits the durable coordinator, then
/// composites the committed board with the retained events of the answered
/// boundary. Failures return a wire-safe resync reason: no fabricated
/// snapshot, no store detail on the wire. Loading gates the bootstrap
/// through `wait_ready`; telemetry and headless commands keep the rest of
/// the backend live meanwhile.
pub async fn BoardBackend::bootstrap_snapshot(
  self : BoardBackend,
) -> Result[@protocol.BoardSnapshot, String] {
  match self.coordinator.wait_ready() {
    Ok(_) => ()
    Err(_) => return Err("snapshot_unavailable")
  }
  for _ in 0..<board_bootstrap_attempts {
    let stream = match self.coordinator.stream_snapshot() {
      Ok(value) => value
      Err(_) => return Err("snapshot_unavailable")
    }
    match self.build_composite(stream) {
      Some(frame) => return Ok(frame)
      None => continue
    }
  }
  Err("history_overflow")
}
