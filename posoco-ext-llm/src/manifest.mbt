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
    requires=[@posoco.Capability::Decision],
  )
}

///|
/// The `model` segment is resident: its initial state is knowable at
/// composition. `ctx` has no reading before core's first projection, so any
/// stale registration is unregistered instead of publishing a placeholder —
/// the segment first appears when a real reading arrives.
pub impl @posoco.Lifecycle for RouterModelPort with fn on_compose(
  self : RouterModelPort,
  ctx : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  self.decision = ctx.decision()
  self.publish_model_status()
  self.publish_provider_event()
  match self.bus {
    Some(bus) =>
      @devkit.publish_status_unregister(
        bus,
        source="posoco_ext_llm",
        segment="ctx",
      )
    None => ()
  }
}

///|
pub extend RouterModelPort with @posoco.Lifecycle::{on_shutdown, on_start}

///|
pub impl @posoco.Lifecycle for RouterModelPort with fn on_start(
  self : RouterModelPort,
) -> Unit {
  // With an attached host group the metadata refresh rides the background:
  // a blocked endpoint (models.dev unreachable, China/Russia networks) must
  // not hold the startup lifecycle. The first session works from cache or
  // the 500k fallback until the fetch lands; later readings pick up the
  // real window. Without the seam (tests, hosts without attach) the refresh
  // stays inline.
  match self.background_group {
    Some(group) => group.spawn_bg(() => self.refresh_model_metadata())
    None => self.refresh_model_metadata()
  }
}

///|
/// Nothing to release: the router holds no resources beyond its slots.
pub impl @posoco.Lifecycle for RouterModelPort with fn on_shutdown(
  self : RouterModelPort,
) -> Unit {
  self.decision = None
}

///|
pub extend RouterModelPort with @posoco.Extension::{extension_id, manifest}
