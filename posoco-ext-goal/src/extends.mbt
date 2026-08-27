// Blessed dot-call promotions (MoonBit v0.10.9 deprecation of implicit
// method promotion). Each declaration re-enables `value.method()` syntax for
// one trait impl owned by this package; without it, callers must use the
// qualified `Trait::method(value)` form. Keep this list limited to methods
// that are actually dot-called within this module.

///|
pub extend GoalRunner with @posoco.Observer::{on_event}

///|
pub extend GoalRunner with @posoco.SystemPromptContributor::{system_prompt}

///|
// `execute` is NOT promoted: the dot-method slot is taken by the
// `GoalRunner::execute` loop (MoonBit has no overloading). Call the tool
// view via `@posoco.ToolProvider::execute(goal, name, call)`.
pub extend GoalRunner with @posoco.ToolProvider::{list_tools}
