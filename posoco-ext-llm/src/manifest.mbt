///|
/// manifest.mbt — Extension impl for RouterModelPort.
///
/// Declares RouterModelPort as a single ModelPort contributor so the
/// Agent's single-model cardinality constraint is satisfied. The router
/// internally manages multiple host-injected model slots.

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
  {
    id: "posoco_ext_llm",
    models: [self],
    tools: [],
    sessions: [],
    observers: [self],
    hooks: [],
    memory: [],
    lifecycle: [self],
    commands: [self],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
/// The `model` segment is resident and its initial state — the active
/// slot's id plus effort — is knowable at composition, so `on_compose`
/// registers it right away instead of waiting for the first response.
/// Register-only: nothing else in the composed view is touched (user
/// ruling 2026-09-04, overturning r1's OQ8 empty-startup-bar).
pub impl @posoco.Lifecycle for RouterModelPort with fn on_compose(
  self : RouterModelPort,
  _ctx : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  self.publish_model_status()
}

///|
/// Nothing to release: the router holds no resources beyond its slots.
pub impl @posoco.Lifecycle for RouterModelPort with fn on_shutdown(
  self : RouterModelPort,
) -> Unit {
  ignore(self)
}

///|
pub extend RouterModelPort with @posoco.Extension::{extension_id, manifest}
