///|
/// Test event channel for the status-protocol tests: one posoco
/// `EventSystem` plus every envelope it delivered, so assertions see exactly
/// what a real listener sees (publisher namespace included).
priv struct StatusCapture {
  system : @posoco.EventSystem
  events : Array[@posoco.EventEnvelope]
}

///|
fn StatusCapture::StatusCapture() -> StatusCapture {
  let system = @posoco.EventSystem()
  let events : Array[@posoco.EventEnvelope] = []
  match system.subscribe(fn(envelope) { events.push(envelope) }) {
    Ok(_) => ()
    Err(_) => abort("test recorder subscription failed")
  }
  { system, events, }
}

///|
/// The owner-bound capability a host mints with
/// `EventSystem::publisher(owner~)` and hands to the publisher under test.
fn StatusCapture::publisher(
  self : StatusCapture,
  owner~ : String,
) -> @posoco.Events {
  match self.system.publisher(owner~) {
    Ok(events) => events
    Err(_) => abort("test publisher capability unavailable: " + owner)
  }
}
