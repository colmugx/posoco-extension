///|
// Blessed dot-call promotions (MoonBit v0.10.9 deprecation of implicit
// method promotion). In-package dot-calls don't need promotion; these
// declarations exist for external consumers and dot-call ergonomics.

///|
pub extend HerdrReporter with @posoco.Observer::{on_event}

///|
pub extend HerdrReporter with @posoco.Lifecycle::{on_shutdown}

///|
pub extend HerdrReporter with @posoco.Extension::{extension_id, manifest}

///|
pub extend HerdrDelegate with @posoco.ToolProvider::{execute}

///|
pub extend HerdrDelegate with @posoco.SystemPromptContributor::{system_prompt}

///|
pub extend HerdrDelegate with @posoco.Extension::{extension_id, manifest}
