// Blessed dot-call promotions (MoonBit v0.10.9 deprecation of implicit
// method promotion). Each declaration re-enables `value.method()` syntax for
// one trait impl owned by this package; without it, callers must use the
// qualified `Trait::method(value)` form. Keep this list limited to methods
// that are actually dot-called within this module.

///|
pub extend RouterModelPort with @posoco.CommandPort::{commands, invoke}

///|
pub extend RouterModelPort with @posoco.ModelPort::{provider_config}

///|
pub extend RouterModelPort with @posoco.Lifecycle::{on_compose}

///|
/// Manager-control surface, dot-callable on the concrete router. The trait
/// form of `select_effort` stays unpromoted: the name belongs to the
/// inherent two-argument `RouterModelPort::select_effort`, so effort control
/// rides the `&ModelManagerControl` reference instead.
pub extend RouterModelPort with @modelmgmt.ModelManagerControl::{
  manager_id,
  list_models,
  active_selection,
  select_model,
}
