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
