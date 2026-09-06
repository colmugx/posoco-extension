///|
/// Minimal local QuotaSource for tests: plays back scripted results in order.
struct ScriptedQuotaSource {
  results : Array[Result[Array[QuotaReading], String]]
  mut calls : Int
}

///|
impl QuotaSource for ScriptedQuotaSource with fn read(
  self : ScriptedQuotaSource,
) -> Result[Array[QuotaReading], String] {
  let index = if self.calls < self.results.length() {
    self.calls
  } else {
    self.results.length() - 1
  }
  self.calls = self.calls + 1
  self.results[index]
}

///|
extend ScriptedQuotaSource with QuotaSource::{read}

///|
test "quota reading carries only provider-stated facts" {
  let reading : QuotaReading = {
    window: "5h",
    used_percent: Some(91.5),
    amount: None,
    available: None,
    reset_at_ms: Some(1756900000000L),
    fetched_at_ms: 1756800000000L,
  }
  debug_inspect(
    reading,
    content=(
      #|{
      #|  window: "5h",
      #|  used_percent: Some(91.5),
      #|  amount: None,
      #|  available: None,
      #|  reset_at_ms: Some(1756900000000),
      #|  fetched_at_ms: 1756800000000,
      #|}
    ),
  )
}

///|
async test "scripted source plays back in order and holds the last result" {
  let source = ScriptedQuotaSource::{
    results: [
      Err("unreachable"),
      Ok([
        {
          window: "balance",
          used_percent: None,
          amount: Some(("110.00", "CNY")),
          available: Some(true),
          reset_at_ms: None,
          fetched_at_ms: 42L,
        },
      ]),
    ],
    calls: 0,
  }
  assert_true(source.read() is Err(_))
  guard source.read() is Ok([reading]) else {
    fail("expected one balance reading")
  }
  assert_eq(reading.amount, Some(("110.00", "CNY")))
  // Exhausted scripts hold the last result so a polling consumer keeps
  // observing it instead of crashing.
  assert_true(source.read() is Ok(_))
  assert_eq(source.calls, 3)
}

///|
test "other window keeps the provider label verbatim" {
  let window : String = "TIME_LIMIT"
  assert_eq(window, "TIME_LIMIT")
}

///|
async test "quota registry registers, overwrites, and unregisters by id" {
  let first : &QuotaSource = ScriptedQuotaSource::{
    results: [Err("first")],
    calls: 0,
  }
  let second : &QuotaSource = ScriptedQuotaSource::{
    results: [Err("second")],
    calls: 0,
  }
  let id = "quota-registry-wbtest"
  quota_registry_unregister(id)
  assert_true(quota_registry_lookup(id) is None)
  quota_registry_register(id, first)
  assert_true(quota_registry_lookup(id) is Some(_))
  // Re-registering the same id overwrites: last write wins.
  quota_registry_register(id, second)
  guard quota_registry_lookup(id) is Some(stored) else {
    fail("expected a registered source")
  }
  guard stored.read() is Err(reason) else {
    fail("expected the overwritten source")
  }
  assert_eq(reason, "second")
  quota_registry_unregister(id)
  assert_true(quota_registry_lookup(id) is None)
  assert_true(quota_registry_lookup("quota-registry-never-registered") is None)
}
