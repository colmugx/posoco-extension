// Blessed dot-call promotions (MoonBit v0.10.9 deprecation of implicit
// method promotion). Each declaration re-enables `value.method()` syntax for
// one trait impl owned by this package; without it, callers must use the
// qualified `Trait::method(value)` form.

///|
pub extend MbtxTools with @posoco.Extension::{extension_id, manifest}

///|
pub extend MbtxTools with @posoco.ToolProvider::{execute, list_tools}

///|
pub extend MbtxTools with @posoco.SystemPromptContributor::{system_prompt}

///|
/// Factory for hosts: one sandboxed MoonBit script tool, default config.
pub fn mbtx_extension() -> MbtxTools {
  MbtxTools::MbtxTools()
}
