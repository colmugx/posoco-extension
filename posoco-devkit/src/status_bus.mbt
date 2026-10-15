///|
/// Process-wide default status bus.
///
/// Push-style statusbar segments (`publish_status_*`) name the bus they
/// publish to explicitly. Provider model ports live below the composition
/// layer that owns the bus, so they cannot receive one through their
/// constructors; this registry lets the composition layer hand the session
/// bus to any publisher by process identity instead. Register at assembly
/// time (`status_bus_register(bus)`), publish from anywhere
/// (`status_bus_default()`). Last write wins: a host that rebuilds its
/// session bus re-registers, and older publishers switch with it.
let status_bus_cell : Ref[EventBus?] = Ref::{ val: None, }

///|
/// Register the process default status bus, replacing any previous one.
pub fn status_bus_register(bus : EventBus) -> Unit {
  status_bus_cell.val = Some(bus)
}

///|
/// The registered default bus, or `None` before the composition layer has
/// registered one. Publishers treat `None` as "nowhere to publish" and skip
/// silently — a missing bus is a rendering gap, never an error.
pub fn status_bus_default() -> EventBus? {
  status_bus_cell.val
}
