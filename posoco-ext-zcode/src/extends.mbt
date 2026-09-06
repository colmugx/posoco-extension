///|
/// Blessed dot-call promotions (MoonBit deprecation of implicit method
/// promotion): re-enables `value.method()` syntax for the trait impls owned
/// by this package.

///|
pub extend ZcodeTools with @posoco.ToolProvider::{execute, list_tools}

///|
pub extend ZcodeExt with @posoco.Extension::{extension_id, manifest}
