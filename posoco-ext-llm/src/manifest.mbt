///|
/// Extension impl for RouterModelPort: declares RouterModelPort as a single
/// ModelPort contributor so the Agent's single-model cardinality constraint
/// is satisfied. The router internally manages multiple host-injected model
/// slots.

///|
pub impl @posoco.Extension for RouterModelPort with fn extension_id(
  _self : RouterModelPort,
) -> String {
  "posoco_ext_llm"
}

///|
pub impl @posoco.Extension for RouterModelPort with fn manifest(
  self : RouterModelPort,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_llm",
    models=[self],
    observers=[self],
    lifecycle=[self],
    commands=[self],
  )
}

///|
/// The `model` segment is resident: its initial state is knowable at
/// composition. `ctx` has no reading before core's first projection, so any
/// stale registration is unregistered instead of publishing a placeholder —
/// the segment first appears when a real reading arrives.
///
/// The decision capability is NOT taken from the composition view: the router
/// resolves it from the active decision slot (`/decision` selection) owned by
/// that slot's provider extension, so a missing/unconfigured decision model
/// turns decision off explicitly instead of silently borrowing another
/// backend.
pub impl @posoco.Lifecycle for RouterModelPort with fn on_compose(
  self : RouterModelPort,
  _ctx : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  // The composition-time publications and the peer-status listener find their
  // channel through the capability handed to the router by the host.
  self.attach_events()
  self.publish_model_status()
  self.publish_decision_selection()
  self.publish_provider_event()
  self.publish_status(@kit_events.Unregister(segment="ctx"))
}

///|
pub extend RouterModelPort with @posoco.Lifecycle::{on_shutdown, on_start}

///|
pub impl @posoco.Lifecycle for RouterModelPort with fn on_start(
  self : RouterModelPort,
) -> Unit {
  self.publish_provider_event()
}

///|
/// The router's slots own their ports; the decision capability rides the
/// active decision slot and needs no release here.
pub impl @posoco.Lifecycle for RouterModelPort with fn on_shutdown(
  self : RouterModelPort,
) -> Unit {
  self |> ignore
}

///|
pub extend RouterModelPort with @posoco.Extension::{extension_id, manifest}
