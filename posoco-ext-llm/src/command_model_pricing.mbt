///|
/// `/model` pricing support.
///
/// Pricing phases are provider-stated facts pulled from the devkit registry
/// at command time, mirroring quick-pick's quota pull: providers without a
/// registered source (or whose source states no phase) are omitted from the
/// catalog — never estimated.

///|
/// Pull the pricing phase for every provider that contributed a slot, in
/// first-seen slot order. Sync and total: an unregistered provider, or a
/// source stating no phase, simply has no entry.
fn RouterModelPort::collect_provider_pricing(
  self : RouterModelPort,
) -> Map[String, @devkit.PricingPhase] {
  let pricing : Map[String, @devkit.PricingPhase] = Map::from_array([])
  for id in self.distinct_provider_ids() {
    match @devkit.pricing_registry_lookup(id) {
      Some(source) =>
        match source.phase() {
          Some(phase) => pricing[id] = phase
          None => ()
        }
      None => ()
    }
  }
  pricing
}

///|
/// Encode one pricing phase verbatim: exactly the three provider-stated
/// strings, nothing invented.
fn pricing_phase_json(phase : @devkit.PricingPhase) -> Json {
  Json::object(
    Map::from_array([
      ("tier", Json::string(phase.tier)),
      ("multiplier", Json::string(phase.multiplier)),
      ("window", Json::string(phase.window)),
    ]),
  )
}
