///|
/// One host-independent Session observation. This is a projection of the
/// existing Posoco/Cetas EventHub, not a second Agent or SessionStore.
/// The host provides a same-user local transport and owns subscriptions.
pub struct SessionReplica {
  session_id : String
  mut epoch : String
  mut cursor : Int32
  mut working : Bool
  mut attached : Bool
}

///|
#derive(Debug, Eq)
pub enum ApplyDecision {
  Applied
  Duplicate
  Ignored
  NeedsSnapshot(String)
}

///|
pub fn SessionReplica::new(session_id : String) -> SessionReplica {
  {
    session_id,
    epoch: "",
    cursor: 0,
    working: false,
    attached: false,
  }
}

///|
pub fn SessionReplica::working(self : SessionReplica) -> Bool {
  self.working
}

///|
pub fn SessionReplica::attached(self : SessionReplica) -> Bool {
  self.attached
}

///|
pub fn SessionReplica::epoch(self : SessionReplica) -> String {
  self.epoch
}

///|
pub fn SessionReplica::cursor(self : SessionReplica) -> Int32 {
  self.cursor
}

///|
pub fn SessionReplica::session_id(self : SessionReplica) -> String {
  self.session_id
}

///|
fn string_field(fields : Map[String, Json], key : String) -> String {
  match fields.get(key) {
    Some(Json::String(value)) => value
    _ => ""
  }
}

///|
fn number_field(fields : Map[String, Json], key : String) -> Int32 {
  match fields.get(key) {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => 0
  }
}

///|
fn bool_field(fields : Map[String, Json], key : String) -> Bool {
  match fields.get(key) {
    Some(Json::True) => true
    _ => false
  }
}

///|
/// Accept only frames for this session, with the current runtime epoch and
/// contiguous per-session broadcast cursor. Unicast frames never move the
/// cursor. A gap or epoch change requires a fresh owner snapshot; callers
/// must not silently continue or replay the mutation that was in flight.
///
/// A snapshot is an authoritative high-water boundary: it sets working
/// immediately even when no new turn event arrives after the viewer joins.
/// All subsequent events stay opaque for each host UI to render unchanged.
pub fn SessionReplica::apply(
  self : SessionReplica,
  frame : Json,
) -> ApplyDecision {
  let fields = match frame {
    Json::Object(fields) => fields
    _ => return NeedsSnapshot("non-object EventHub frame")
  }
  let session_id = string_field(fields, "session_id")
  if session_id != self.session_id {
    return Ignored
  }
  let kind = string_field(fields, "type")
  let epoch = string_field(fields, "runtime_epoch")
  if epoch == "" {
    self.attached = false
    return NeedsSnapshot("missing runtime epoch")
  }
  let cursor = number_field(fields, "cursor")
  let advances = bool_field(fields, "cursor_advance")
  if kind == "session.snapshot" {
    let high_water = number_field(fields, "high_water_cursor")
    let baseline = if high_water > cursor { high_water } else { cursor }
    if self.attached && epoch == self.epoch && baseline < self.cursor {
      return Duplicate
    }
    self.epoch = epoch
    self.cursor = baseline
    self.working = bool_field(fields, "busy")
    self.attached = true
    return Applied
  }
  if !self.attached {
    return NeedsSnapshot("event before session snapshot")
  }
  if epoch != self.epoch {
    self.attached = false
    return NeedsSnapshot("runtime epoch changed")
  }
  if advances {
    if cursor <= self.cursor {
      return Duplicate
    }
    if cursor != self.cursor + 1 {
      self.attached = false
      return NeedsSnapshot("session cursor gap")
    }
    self.cursor = cursor
  }
  match kind {
    "turn.accepted" | "turn.started" => self.working = true
    "turn.completed" | "turn.failed" | "turn.cancelled" =>
      self.working = false
    _ => ()
  }
  Applied
}
