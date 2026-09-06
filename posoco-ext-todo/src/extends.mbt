// Blessed dot-call promotions (MoonBit deprecation of implicit method
// promotion). Each declaration re-enables `value.method()` syntax for one
// trait impl owned by this package; without it, callers must use the
// qualified `Trait::method(value)` form. Keep this list limited to methods
// that are actually dot-called within this module.

///|
pub extend TodoList with @posoco.CommandPort::{invoke}

///|
pub extend TodoList with @posoco.ToolProvider::{execute, list_tools}

///|
pub extend TodoList with @posoco.Extension::{extension_id, manifest}

///|
pub extend TodoList with @posoco.SystemPromptContributor::{system_prompt}

///|
pub extend TodoList with @posoco.Lifecycle::{on_compose}

///|
pub extend TodoStatus with Show::{to_string}
