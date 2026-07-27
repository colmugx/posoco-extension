///|
// ============================================================================
// posoco-ext-read — Extension manifest.
//
// ReadTools implements both ToolProvider (declares + executes the `read` tool)
// and SystemPromptContributor (emits the "use read first" guidance). This file
// adds the third trait — `@posoco.Extension` — so the agent composer can
// discover all of ReadTools' port contributions through one self-reporting
// interface.
//
// The manifest is intentionally a method on the existing struct (not a free
// factory function), so a host that already holds a `ReadTools` instance can
// pass it directly to `Agent::new(exts=[read_tools_instance], config~)`.
// ============================================================================

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
/// Declare the ports ReadTools contributes: ToolProvider + SystemPromptContributor.
/// The same `self` reference appears under both fields because ReadTools
/// implements both port traits on the same struct.
pub impl @posoco.Extension for ReadTools with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_read",
    models: [],
    tools: [self],
    sessions: [],
    observers: [],
    compressors: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [self],
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
