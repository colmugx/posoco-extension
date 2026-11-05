///|
/// `status_op` — the status-bar protocol.
///
/// `publish_status_*` publishes `@kit_events.StatusChanged(op)` through the
/// process default `EventSystem` (see `events_system.mbt`); the payload fields
/// are the ones the status bridge reads, one per argument, with no derived or
/// implicit field.
///
/// Ownership of a segment (who may write it) is enforced by the bridge, not
/// here: the `source` of the first register/update for a segment owns it.

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
/// One status-bar operation.
#derive(Eq, Debug)
pub(all) enum StatusOp {
  Register(
    segment~ : String,
    label~ : String?,
    priority~ : Int32,
    value~ : String?,
    color~ : String?
  )
  Update(segment~ : String, value~ : String)
  Unregister(segment~ : String)
}

///|
pub extend StatusOp with Eq::{not_equal, equal}

///|
pub extend StatusOp with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Publish a register op: claim `segment` with display metadata. `priority`
/// orders segments on the bar (ascending, left to right). `color` is a
/// semantic role from `status_color_roles()`.
///
/// The op travels as `@kit_events.StatusChanged(@kit_events.Register(..))` on
/// the process default event system; with no registered system the call is a
/// silent no-op.
pub fn publish_status_register(
  source~ : String,
  segment~ : String,
  label? : String,
  priority~ : Int32 = 0,
  value? : String,
  color? : String,
) -> Unit {
  publish_protocol_event(
    source,
    @kit_events.StatusChanged(
      @kit_events.Register(segment~, label~, priority~, value~, color~),
    ),
  )
}

///|
/// Publish an update op: set the segment's value. For a segment the bridge
/// has not seen, this acts as an implicit register with default priority.
///
/// The op travels as `@kit_events.StatusChanged(@kit_events.Update(..))`;
/// with no registered system the call is a silent no-op.
pub fn publish_status_update(
  source~ : String,
  segment~ : String,
  value~ : String,
) -> Unit {
  publish_protocol_event(
    source,
    @kit_events.StatusChanged(@kit_events.Update(segment~, value~)),
  )
}

///|
/// Publish an unregister op: release the segment.
///
/// The op travels as `@kit_events.StatusChanged(@kit_events.Unregister(..))`;
/// with no registered system the call is a silent no-op.
pub fn publish_status_unregister(source~ : String, segment~ : String) -> Unit {
  publish_protocol_event(
    source,
    @kit_events.StatusChanged(@kit_events.Unregister(segment~)),
  )
}
