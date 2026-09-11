///|
/// Minimal local PricingSource for tests: returns one fixed phase (or None).
struct FixedPricingSource {
  answer : PricingPhase?
}

///|
impl PricingSource for FixedPricingSource with fn phase(
  self : FixedPricingSource,
) -> PricingPhase? {
  self.answer
}

///|
test "pricing source states its fixed phase or none" {
  let peak : PricingPhase = {
    tier: "peak",
    multiplier: "2x",
    window: "9:00 ~ 12:00, 14:00 ~ 18:00",
  }
  let source : &PricingSource = FixedPricingSource::{ answer: Some(peak), }
  guard source.phase() is Some(stated) else { fail("expected the fixed phase") }
  assert_eq(stated.tier, "peak")
  assert_eq(stated.multiplier, "2x")
  assert_eq(stated.window, "9:00 ~ 12:00, 14:00 ~ 18:00")
  let silent : &PricingSource = FixedPricingSource::{ answer: None, }
  assert_true(silent.phase() is None)
}

///|
test "pricing registry registers, overwrites, and unregisters by id" {
  let first : &PricingSource = FixedPricingSource::{
    answer: Some({
      tier: "peak",
      multiplier: "2x",
      window: "9:00 ~ 12:00, 14:00 ~ 18:00",
    }),
  }
  let second : &PricingSource = FixedPricingSource::{
    answer: Some({
      tier: "off-peak",
      multiplier: "1x",
      window: "9:00 ~ 12:00, 14:00 ~ 18:00",
    }),
  }
  let id = "pricing-wbtest"
  pricing_registry_unregister(id)
  assert_true(pricing_registry_lookup(id) is None)
  pricing_registry_register(id, first)
  assert_true(pricing_registry_lookup(id) is Some(_))
  // Re-registering the same id overwrites: last write wins.
  pricing_registry_register(id, second)
  guard pricing_registry_lookup(id) is Some(stored) else {
    fail("expected a registered source")
  }
  guard stored.phase() is Some(phase) else {
    fail("expected the overwritten source's phase")
  }
  assert_eq(phase.tier, "off-peak")
  pricing_registry_unregister(id)
  assert_true(pricing_registry_lookup(id) is None)
  assert_true(pricing_registry_lookup("pricing-never-registered") is None)
}
