///|
/// Blessed dot-call promotions (MoonBit deprecation of implicit method
/// promotion): re-enables `value.method()` syntax for the trait impls owned
/// by this package.

///|
pub extend SubagentTools with @posoco.ToolProvider::{list_tools, execute}

///|
pub extend SubagentTools with @posoco.PipelineHook::{before_model}

///|
pub extend SubagentTools with @posoco.Extension::{extension_id, manifest}
