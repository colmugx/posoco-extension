///|
/// Blessed dot-call promotions (lazytools `extends.mbt` precedent). Each
/// declaration re-enables `value.method()` syntax for one trait impl owned
/// by this package; without it, callers use the qualified
/// `Trait::method(value)` form. Keep this list limited to methods actually
/// dot-called within this module or its tests.

///|
pub extend Profiles with @posoco.Extension::{extension_id, manifest}

///|
pub extend Profiles with @posoco.ToolProvider::{execute, list_tools}

///|
pub extend Profiles with @posoco.PipelineHook::{before_model}

///|
pub extend Profiles with @posoco.Observer::{on_event_at}

///|
pub extend Profiles with @posoco.SystemPromptContributor::{system_prompt}

///|
pub extend Profiles with @posoco.CommandPort::{commands, invoke}

///|
pub extend Profiles with @posoco.Lifecycle::{on_compose}
