///|
/// Start without a baseline; a saved transport cursor alone is insufficient.
/// A checked example is in `client.mbt.md`.
pub fn BoardReplica::empty() -> BoardReplica {
  {
    task_records: [],
    attempt_records: [],
    board_revision: 0L,
    sequence: 0L,
    baseline: false,
  }
}

///|
/// Advertise only this live replica's baseline and transport cursor.
pub fn BoardReplica::hello(self : BoardReplica) -> @protocol.BoardHello {
  {
    last_seq: self.sequence,
    protocol_version: @protocol.protocol_version(),
    has_board_snapshot: self.baseline,
  }
}

///|
/// Detached records, including both nested task arrays.
pub fn BoardReplica::tasks(self : BoardReplica) -> Array[ClientBoardTask] {
  self.task_records.map(task => task.copy_detached())
}

///|
/// Detached array of immutable attempt records.
pub fn BoardReplica::attempts(self : BoardReplica) -> Array[ClientAttempt] {
  self.attempt_records.copy()
}

///|
pub fn BoardReplica::revision(self : BoardReplica) -> Int64 {
  self.board_revision
}

///|
pub fn BoardReplica::last_seq(self : BoardReplica) -> Int64 {
  self.sequence
}

///|
pub fn BoardReplica::has_snapshot(self : BoardReplica) -> Bool {
  self.baseline
}

///|
/// Deep detached clone for clone-on-update rendering: applying frames to the
/// copy never mutates this replica's retained records. A checked example is
/// in `client.mbt.md`.
pub fn BoardReplica::copy(self : BoardReplica) -> BoardReplica {
  {
    task_records: self.task_records.map(task => task.copy_detached()),
    attempt_records: self.attempt_records.copy(),
    board_revision: self.board_revision,
    sequence: self.sequence,
    baseline: self.baseline,
  }
}

///|
fn BoardReplica::invalidate(
  self : BoardReplica,
  reason : String,
) -> ApplyOutcome {
  self.task_records = []
  self.attempt_records = []
  self.board_revision = 0L
  self.sequence = 0L
  self.baseline = false
  NeedsSnapshot(reason)
}

///|
/// Replace the entire projection authoritatively; never replay its suffix.
pub fn BoardReplica::apply_snapshot(
  self : BoardReplica,
  frame : @protocol.BoardSnapshot,
) -> ApplyOutcome {
  match decode_board_snapshot(frame) {
    Err(UnsupportedProtocolVersion) =>
      TerminalProtocolError("unsupported_protocol_version")
    Err(InvalidData(reason)) => self.invalidate(reason)
    Ok(decoded) => {
      self.task_records = decoded.tasks
      self.attempt_records = decoded.attempts
      self.board_revision = decoded.revision
      self.sequence = decoded.last_seq
      self.baseline = true
      Applied
    }
  }
}

///|
/// Duplicates are ignored before inspecting payload or revision. New events
/// require an exact next sequence. Telemetry advances only the cursor;
/// Board events require a baseline and same-or-next Board revision.
pub fn BoardReplica::apply_event(
  self : BoardReplica,
  event : @protocol.BoardWireEvent,
) -> ApplyOutcome {
  if event.seq <= self.sequence {
    return Duplicate
  }
  if !safe_integer(event.seq) || event.seq != self.sequence + 1L {
    return self.invalidate("event sequence gap")
  }
  if !event.kind.has_prefix("board.") {
    self.sequence = event.seq
    return Applied
  }
  if !self.baseline {
    return self.invalidate("board event requires snapshot")
  }
  if !safe_integer(event.board_revision) ||
    (
      event.board_revision != self.board_revision &&
      event.board_revision != self.board_revision + 1L
    ) {
    return self.invalidate("board revision discontinuity")
  }
  let update = event_entity(event) catch {
    DecodeFailure(reason) => return self.invalidate(reason)
  }
  match update {
    Task(entity) => {
      let index = self.task_records.search_by(task => task.id == entity.id)
      match index {
        Some(index) => self.task_records[index] = entity
        None => self.task_records.push(entity)
      }
    }
    Attempt(entity) => {
      let index = self.attempt_records.search_by(attempt => {
        attempt.id == entity.id
      })
      match index {
        Some(index) => self.attempt_records[index] = entity
        None => self.attempt_records.push(entity)
      }
    }
  }
  self.board_revision = event.board_revision
  self.sequence = event.seq
  Applied
}

///|
/// Apply one decoded server frame. Command results do not change the
/// projection or cursor. Protocol errors return the code, never the message.
/// A checked example is in `client.mbt.md`.
pub fn BoardReplica::apply_frame(
  self : BoardReplica,
  frame : @protocol.BoardServerFrame,
) -> ApplyOutcome {
  match frame {
    Snapshot(frame) => self.apply_snapshot(frame)
    Event(event) => self.apply_event(event)
    CommandResult(result) => CommandSettled(result)
    ResyncRequired(reason~, ..) => self.invalidate(reason)
    Error(code~, ..) => TerminalProtocolError(code)
  }
}

///|
/// Decode and apply a raw frame. Malformed input discards the baseline;
/// unsupported protocol versions are terminal with a stable local code. A
/// checked example is in `client.mbt.md`.
pub fn BoardReplica::apply_text(
  self : BoardReplica,
  text : String,
) -> ApplyOutcome {
  match @protocol.decode_server_frame(text) {
    Ok(frame) => self.apply_frame(frame)
    Err(UnsupportedVersion(..)) => {
      let _ = self.invalidate("unsupported_protocol_version")
      TerminalProtocolError("unsupported_protocol_version")
    }
    Err(_) => self.invalidate("malformed server frame")
  }
}
