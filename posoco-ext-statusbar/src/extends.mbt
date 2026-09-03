// Blessed dot-call promotions (MoonBit v0.10.9 deprecation of implicit
// method promotion). Each declaration re-enables `value.method()` syntax for
// one trait impl owned by this package; without it, callers must use the
// qualified `Trait::method(value)` form. Keep this list limited to methods
// that are actually dot-called within this module.

///|
pub extend StatusBar with @posoco.CommandPort::{invoke}

///|
pub extend StatusBar with @posoco.Lifecycle::{on_compose}
