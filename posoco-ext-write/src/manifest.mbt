///|
// ============================================================================
// posoco-ext-write — Extension manifest.
//
// WriteTools implements both ToolProvider (declares + executes the `write`
// tool) and SystemPromptContributor (emits write-specific guidance). This
// file adds `@posoco.Extension` so the agent composer can discover both
// port contributions through one self-reporting interface.
// ============================================================================

///|
pub impl @posoco.Extension for WriteTools with fn extension_id(_self) -> String {
  "posoco_ext_write"
}

///|
pub impl @posoco.Extension for WriteTools with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_write",
    models: [],
    tools: [self],
    sessions: [],
    observers: [],
    pre_model_hooks: [],
    pre_tool_hooks: [],
    post_event_hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [self],
  }
}

///|
pub extend WriteTools with @posoco.Extension::{extension_id, manifest}

///|
/// Convenience factory: construct a WriteTools and return it. Hosts that
/// already hold a WriteTools instance should pass it directly.
pub fn write_extension() -> WriteTools {
  WriteTools::WriteTools()
}
