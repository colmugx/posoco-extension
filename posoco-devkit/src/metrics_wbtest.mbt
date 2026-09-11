///|
/// Minimal local ModelMetricsSource for tests: returns one fixed result.
struct FixedMetricsSource {
  answer : Result[Array[MetricsPoint], String]
}

///|
impl ModelMetricsSource for FixedMetricsSource with fn read(
  self : FixedMetricsSource,
) -> Result[Array[MetricsPoint], String] {
  self.answer
}

///|
extend FixedMetricsSource with ModelMetricsSource::{read}

///|
async test "metrics source returns its fixed points or error" {
  let source = FixedMetricsSource::{
    answer: Ok([
      {
        model: "gpt-6-astra",
        effort: "medium",
        iq: 117.0,
        cost_usd: 2.37,
        passed: 58,
        total: 60,
        tokens: Some(152760.0),
        minutes: Some(9.0),
      },
    ]),
  }
  guard source.read() is Ok([point]) else { fail("expected one metrics point") }
  assert_eq(point.model, "gpt-6-astra")
  assert_eq(point.effort, "medium")
  assert_eq(point.iq, 117.0)
  assert_eq(point.cost_usd, 2.37)
  assert_eq(point.passed, 58)
  assert_eq(point.total, 60)
  assert_eq(point.tokens, Some(152760.0))
  assert_eq(point.minutes, Some(9.0))
  let dark : &ModelMetricsSource = FixedMetricsSource::{ answer: Err("down"), }
  guard dark.read() is Err(reason) else { fail("expected the error result") }
  assert_eq(reason, "down")
}

///|
async test "metrics registry registers, overwrites, and unregisters by id" {
  let first : &ModelMetricsSource = FixedMetricsSource::{
    answer: Ok([
      {
        model: "gpt-6-astra",
        effort: "medium",
        iq: 117.0,
        cost_usd: 2.37,
        passed: 58,
        total: 60,
        // The source omitted both fields: omitted, never zero-filled.
        tokens: None,
        minutes: None,
      },
    ]),
  }
  let second : &ModelMetricsSource = FixedMetricsSource::{
    answer: Ok([
      {
        model: "gpt-6-astra",
        effort: "low",
        iq: 110.0,
        cost_usd: 1.20,
        passed: 55,
        total: 60,
        tokens: Some(148500.0),
        minutes: Some(8.9),
      },
    ]),
  }
  let id = "metrics-wbtest"
  metrics_registry_unregister(id)
  assert_true(metrics_registry_lookup(id) is None)
  metrics_registry_register(id, first)
  assert_true(metrics_registry_lookup(id) is Some(_))
  // Re-registering the same id overwrites: last write wins.
  metrics_registry_register(id, second)
  guard metrics_registry_lookup(id) is Some(stored) else {
    fail("expected a registered source")
  }
  guard stored.read() is Ok([picked]) else {
    fail("expected the overwritten source's points")
  }
  assert_eq(picked.effort, "low")
  assert_eq(picked.tokens, Some(148500.0))
  assert_eq(picked.minutes, Some(8.9))
  metrics_registry_unregister(id)
  assert_true(metrics_registry_lookup(id) is None)
  // Unregistering an unknown id is a no-op.
  metrics_registry_unregister("metrics-never-registered")
  assert_true(metrics_registry_lookup("metrics-never-registered") is None)
}
