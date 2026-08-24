///|
/// Self-report StatusBar's port contributions to the agent composer.
pub impl @posoco.Extension for StatusBar with fn extension_id(_self) -> String {
  "posoco_ext_statusbar"
}

///|
/// Declare the ports StatusBar contributes: Observer (turn/token telemetry)
/// and CommandPort (/statusbar). The same `self` reference appears under
/// every field so all views share one status.
pub impl @posoco.Extension for StatusBar with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_statusbar",
    models: [],
    tools: [],
    sessions: [],
    observers: [self],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [self],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
/// Expose Extension methods on StatusBar for dot-syntax callers and so
/// `&StatusBar` coerces to `&@posoco.Extension` when placed in an
/// `Array[&@posoco.Extension]`.
pub extend StatusBar with @posoco.Extension::{extension_id, manifest}
