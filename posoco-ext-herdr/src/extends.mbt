///|
// Blessed dot-call promotions (MoonBit v0.10.9 deprecation of implicit
// method promotion). Limited to methods actually dot-called in this module.

///|
pub extend HerdrReporter with @posoco.Observer::{on_event}

///|
pub extend HerdrReporter with @posoco.Extension::{extension_id, manifest}
