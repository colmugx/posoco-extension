///|
/// One authoritative pricing phase as stated by a provider extension.
/// `tier` is "peak" or "off-peak"; `multiplier` is the provider's own
/// multiplier text (e.g. "2x"); `window` is the provider's own display text
/// naming the surcharge window (e.g. "9:00 ~ 12:00, 14:00 ~ 18:00"). Nothing
/// here is estimated locally: a PricingSource states phases, devkit never
/// derives them.
pub(all) struct PricingPhase {
  tier : String
  multiplier : String
  window : String
} derive(Eq, @debug.Debug)

///|
/// A source of authoritative provider pricing phases. Implementations live
/// in provider adapter extensions, where the vendor rule resides; consumers
/// (model catalogs) depend only on this trait. `phase` returning `None`
/// means no pricing is known — never a fallback estimate.
pub(open) trait PricingSource {
  fn phase(Self) -> PricingPhase?
}

///|
/// Process-wide registry of named pricing sources. Provider adapter
/// extensions register their source under their provider id on every factory
/// `build`/`refresh` that yields a configured provider, so each registration
/// reflects the currently configured provider (last write wins). Pull-style
/// consumers such as the `/model` catalog command look the provider id up at
/// command time and read the phase live. There is deliberately no
/// unregistration on `Unconfigured` builds: a stale entry is never read
/// because consumers only query provider ids behind their slots.
let pricing_registry_cell : Ref[Map[String, &PricingSource]] = Ref::{
  val: Map::from_array([]),
}

///|
/// Register `source` under `id`, replacing any previous registration for
/// that id (last write wins).
pub fn pricing_registry_register(id : String, source : &PricingSource) -> Unit {
  pricing_registry_cell.val[id] = source
}

///|
/// The source registered under `id`, or `None` when nothing is registered.
pub fn pricing_registry_lookup(id : String) -> &PricingSource? {
  pricing_registry_cell.val.get(id)
}

///|
/// Drop the registration under `id`; a no-op for unknown ids.
pub fn pricing_registry_unregister(id : String) -> Unit {
  pricing_registry_cell.val.remove(id)
}
