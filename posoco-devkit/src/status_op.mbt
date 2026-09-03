///|
/// `status_op` — the wire protocol shared by every status-bar publisher and
/// the statusbar bridge (see `docs/statusbar-bridge/r1-plan.md`).
///
/// Extensions publish on topic "status" through the three helpers; the
/// bridge subscribes to the bus and decodes each event with
/// `decode_status_op`. Payloads are Json objects, so the protocol survives
/// transport mapping and third-party publishers. Malformed events decode to
/// `None` and are silently dropped — decoding never raises, so one bad
/// publisher cannot crash the host.
///
/// Ownership of a segment (who may write it) is enforced by the bridge, not
/// here: the `source` of the first register/update for a segment owns it.

///|
/// The bus topic every status-bridge event travels on. Supersedes the
/// statusbar's former `STATUSBAR_TOPIC` convention.
pub const STATUS_TOPIC : String = "status"

///|
/// The closed vocabulary of semantic color roles a register may declare.
/// Roles are semantic markers aligned with host theme vocabulary (e.g. the
/// cetas-js theme role names); raw color values (ANSI/hex) never travel on
/// the protocol, and hosts may ignore any declaration. Returns a fresh
/// array per call (`default_ignore_patterns` style): uppercase globals
/// must be `const`, and `const` rejects arrays.
pub fn status_color_roles() -> Array[String] {
  ["accent", "warning", "error", "success", "info", "muted"]
}

///|
/// Whether `role` belongs to `status_color_roles()`. The protocol carries
/// any declared string; vocabulary enforcement is the consumer's (bridge's)
/// job.
pub fn is_status_color_role(role : String) -> Bool {
  status_color_roles().contains(role)
}

///|
/// One decoded status-bar operation.
pub(all) enum StatusOp {
  Register(
    segment~ : String,
    label~ : String?,
    priority~ : Int,
    value~ : String?,
    color~ : String?
  )
  Update(segment~ : String, value~ : String)
  Unregister(segment~ : String)
} derive(Eq, Debug)

///|
/// Publish a register op: claim `segment` with display metadata. `priority`
/// orders segments on the bar (ascending, left to right). `label`, `value`
/// and `color` keys are emitted only when present; `priority` is always
/// emitted. `color` is a semantic role from `status_color_roles()`.
pub fn publish_status_register(
  bus : EventBus,
  source~ : String,
  segment~ : String,
  label? : String,
  priority? : Int = 0,
  value? : String,
  color? : String,
) -> Unit {
  let pairs : Array[(String, Json)] = [
    ("op", Json::string("register")),
    ("segment", Json::string(segment)),
    ("priority", Json::number(priority.to_double())),
  ]
  match label {
    Some(l) => pairs.push(("label", Json::string(l)))
    None => ()
  }
  match value {
    Some(v) => pairs.push(("value", Json::string(v)))
    None => ()
  }
  match color {
    Some(c) => pairs.push(("color", Json::string(c)))
    None => ()
  }
  bus.publish({
    source,
    topic: STATUS_TOPIC,
    data: Json::object(Map::from_array(pairs)),
  })
}

///|
/// Publish an update op: set the segment's value. For a segment the bridge
/// has not seen, this acts as an implicit register with default priority.
pub fn publish_status_update(
  bus : EventBus,
  source~ : String,
  segment~ : String,
  value~ : String,
) -> Unit {
  bus.publish({
    source,
    topic: STATUS_TOPIC,
    data: Json::object({
      "op": Json::string("update"),
      "segment": Json::string(segment),
      "value": Json::string(value),
    }),
  })
}

///|
/// Publish an unregister op: release the segment.
pub fn publish_status_unregister(
  bus : EventBus,
  source~ : String,
  segment~ : String,
) -> Unit {
  bus.publish({
    source,
    topic: STATUS_TOPIC,
    data: Json::object({
      "op": Json::string("unregister"),
      "segment": Json::string(segment),
    }),
  })
}

///|
/// Decode a bus event into a `StatusOp`. Returns `None` when the event is
/// not on the status topic, the payload is not an object, `op` is missing
/// or unknown, or a required field is missing or wrongly typed — callers
/// drop the event and move on. `priority` is the one forgiving field:
/// absent or non-numeric decodes to 0. Never raises.
pub fn decode_status_op(event : BusEvent) -> StatusOp? {
  if event.topic != STATUS_TOPIC {
    return None
  }
  match event.data {
    Object(fields) =>
      match fields.get("op") {
        Some(String("register")) => register_from(fields)
        Some(String("update")) => update_from(fields)
        Some(String("unregister")) => unregister_from(fields)
        _ => None
      }
    _ => None
  }
}

///|
/// Strict decode for register payloads: `label`, `value` and `color` are
/// optional but must be strings when present — a wrongly typed one rejects
/// the whole event. `color` is NOT checked against `status_color_roles()`
/// here: a present-but-unknown role still decodes, and vocabulary
/// enforcement is the consumer's (bridge's) job via `is_status_color_role`.
fn register_from(fields : Map[String, Json]) -> StatusOp? {
  let segment = match fields.get("segment") {
    Some(String(s)) => s
    _ => return None
  }
  let priority = match fields.get("priority") {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
  let label = match fields.get("label") {
    Some(String(l)) => Some(l)
    Some(_) => return None
    None => None
  }
  let value = match fields.get("value") {
    Some(String(v)) => Some(v)
    Some(_) => return None
    None => None
  }
  let color = match fields.get("color") {
    Some(String(c)) => Some(c)
    Some(_) => return None
    None => None
  }
  Some(Register(segment~, label~, priority~, value~, color~))
}

///|
fn update_from(fields : Map[String, Json]) -> StatusOp? {
  let segment = match fields.get("segment") {
    Some(String(s)) => s
    _ => return None
  }
  let value = match fields.get("value") {
    Some(String(v)) => v
    _ => return None
  }
  Some(Update(segment~, value~))
}

///|
fn unregister_from(fields : Map[String, Json]) -> StatusOp? {
  let segment = match fields.get("segment") {
    Some(String(s)) => s
    _ => return None
  }
  Some(Unregister(segment~))
}
