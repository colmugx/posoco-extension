///|
/// wham/usage parsing and probe orchestration.

///|
fn codex_usage_fixture() -> Json {
  {
    "plan_type": "plus",
    "rate_limit": {
      "limit_reached": false,
      "primary_window": {
        "used_percent": 49.5,
        "limit_window_seconds": 18000,
        "reset_at": 1777936568,
      },
      "secondary_window": {
        "used_percent": 80.0,
        "limit_window_seconds": 604800,
        "reset_after_seconds": 316705,
      },
    },
    "credits": { "has_credits": false, "unlimited": false, "balance": "0" },
  }
}

///|
fn expect_codex_usage(
  payload : Json,
  fetched_at_ms~ : Int64,
) -> Array[@devkit.QuotaReading] raise {
  match parse_codex_usage(payload, fetched_at_ms~) {
    Ok(readings) => readings
    Err(reason) => fail(reason)
  }
}

///|
test "parse codex usage maps windows by duration and credits as balance" {
  let fetched_at_ms = 1757000000000L
  let readings = expect_codex_usage(codex_usage_fixture(), fetched_at_ms~)
  assert_eq(readings.length(), 3)
  // Primary is labeled by its duration (300 minutes → 5h), not its slot.
  assert_eq(readings[0].window, "5h")
  assert_eq(readings[0].used_percent, Some(49.5))
  assert_eq(readings[0].reset_at_ms, Some(1777936568L * 1000L))
  // Secondary is weekly; only reset_after_seconds is stated, so the reset
  // anchors to the fetch time.
  assert_eq(readings[1].window, "weekly")
  assert_eq(readings[1].used_percent, Some(80.0))
  assert_eq(readings[1].reset_at_ms, Some(fetched_at_ms + 316705L * 1000L))
  // Credits ride the balance vocabulary shared with the header capture.
  assert_eq(readings[2].window, "balance")
  assert_eq(readings[2].amount, Some(("0", "credits")))
  assert_eq(readings[2].available, Some(false))
}

///|
test "parse codex usage labels a weekly-only plan by duration" {
  // Some plans temporarily expose only the weekly window in the primary
  // slot; the duration, not the slot name, owns the label.
  let payload : Json = {
    "rate_limit": {
      "primary_window": {
        "used_percent": 12.0,
        "limit_window_seconds": 604800,
        "reset_at": 1777936568,
      },
    },
  }
  let readings = expect_codex_usage(payload, fetched_at_ms=1757000000000L)
  assert_eq(readings.length(), 1)
  assert_eq(readings[0].window, "weekly")
}

///|
test "parse codex usage rejects non-objects and skips empty windows" {
  assert_true(parse_codex_usage(Json::number(1.0), fetched_at_ms=0L) is Err(_))
  let payload : Json = {
    "rate_limit": { "primary_window": { "limit_window_seconds": 18000 } },
  }
  let readings = expect_codex_usage(payload, fetched_at_ms=0L)
  assert_eq(readings.length(), 0)
}

///|
priv struct FakeUsageTransport {
  mut url : String
  body : String
}

///|
impl OpenAIModelsHttpTransport for FakeUsageTransport with fn get(
  self : FakeUsageTransport,
  url : String,
  _headers : Map[String, String],
) -> OpenAIModelsHttpResponse raise @posoco.ModelError {
  self.url = url
  OpenAIModelsHttpResponse::{ status: 200, body: self.body, }
}

///|
async test "fetch codex usage probes the wham endpoint" {
  let fake = FakeUsageTransport::{
    url: "",
    body: "{\"rate_limit\":{\"primary_window\":{\"used_percent\":10.0,\"limit_window_seconds\":18000,\"reset_at\":1777936568}}}",
  }
  let borrowed : &OpenAIModelsHttpTransport = fake
  let result = fetch_codex_usage_with_transport(
    borrowed,
    "https://chatgpt.com/backend-api/codex",
    "token",
    "account",
    now_ms=fn() { 1757000000000L },
  )
  assert_eq(fake.url, "https://chatgpt.com/backend-api/wham/usage")
  match result {
    Ok(readings) => {
      assert_eq(readings.length(), 1)
      assert_eq(readings[0].window, "5h")
    }
    Err(reason) => fail(reason)
  }
  // An empty account id fails fast without issuing a request.
  assert_true(
    fetch_codex_usage_with_transport(
      borrowed,
      "https://chatgpt.com/backend-api/codex",
      "token",
      "",
      now_ms=fn() { 1757000000000L },
    )
    is Err(_),
  )
  assert_eq(
    codex_usage_url("https://chatgpt.com/backend-api/codex/"),
    "https://chatgpt.com/backend-api/wham/usage",
  )
}
