///|
/// Self-report ReadTools' port contributions to the agent composer.
///
/// `id` is the manifest identifier used in composition diagnostics (tool
/// collision messages, observer attribution, etc.). It is NOT used for
/// routing or persistence.
pub impl @posoco.Extension for ReadTools with fn extension_id(_self) -> String {
  "posoco_ext_read"
}

///|
/// Declare the ports ReadTools contributes: ToolProvider.
/// The same `self` reference appears under both fields because ReadTools
/// implements both port traits on the same struct.
pub impl @posoco.Extension for ReadTools with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_read",
    models: [],
    tools: [self],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
/// Expose Extension methods on ReadTools for dot-syntax callers and so
/// `&ReadTools` coerces to `&@posoco.Extension` when placed in an
/// `Array[&@posoco.Extension]`.
pub extend ReadTools with @posoco.Extension::{extension_id, manifest}

///|
/// Convenience factory: construct a ReadTools and return its Extension view.
/// Hosts that already hold a ReadTools instance should pass it directly
/// instead of calling this helper.
pub fn read_extension() -> ReadTools {
  ReadTools::ReadTools()
}
