///|
/// `events_system` — the process-default posoco `@events` / `EventSystem`
/// injection point.
///
/// Cross-extension facts travel as the closed payload ADTs in `@kit_events`
/// delivered by posoco's `EventSystem`. The devkit `publish_status_*` helpers
/// publish `@kit_events.StatusChanged` through the system registered here.
///
/// Those publishers live at every layer of the product — provider model ports
/// sit below the composition layer that owns the session's event system, so
/// they cannot receive one through a constructor. This registry is how the
/// composition layer hands its system to any publisher by process identity
/// instead. Register at assembly time (`events_system_register(system)`),
/// publish from anywhere. Last write wins: a host that rebuilds its session
/// registers again, and older publishers switch with it.

///|
let events_system_cell : Ref[@posoco.EventSystem?] = Ref::{ val: None, }

///|
/// Register the process default event system, replacing any previous one.
/// Called by the host's session assembly, which also hands the same system to
/// the `Agent` that takes exclusive ownership of it.
pub fn events_system_register(system : @posoco.EventSystem) -> Unit {
  events_system_cell.val = Some(system)
}

///|
/// The registered default event system, or `None` before the composition layer
/// has registered one. Publishers treat `None` as "nowhere to publish" and skip
/// silently — a missing system is a rendering gap, never an error.
pub fn events_system_default() -> @posoco.EventSystem? {
  events_system_cell.val
}

///|
/// Publish one protocol event on behalf of `source`.
///
/// The capability is minted per call (`system.publisher(owner=source)`), so the
/// event is tagged with `Extension(source)` and no capability is retained
/// beyond the call. A missing or closed system is a silent no-op: publication
/// is never an error path, and a publisher must not raise at its call site.
fn publish_protocol_event(source : String, event : @posoco.Event) -> Unit {
  match events_system_default() {
    Some(system) =>
      match system.publisher(owner=source) {
        Ok(publisher) => ignore(publisher.publish(event))
        // Closed system: the host is shutting down, so the notification has
        // nowhere to land. Dropping it keeps publish_status_* non-raising.
        Err(_) => ()
      }
    None => ()
  }
}
