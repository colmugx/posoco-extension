///|
/// Fixtures mirror codex-rs's own rate-limit header test suite
/// (codex-rs/codex-api/src/rate_limits.rs).

///|
fn codex_headers_full() -> @http.Headers {
  {
    "x-codex-primary-used-percent": "12.5",
    "x-codex-primary-window-minutes": "300",
    "x-codex-primary-reset-at": "1704069000",
    "x-codex-secondary-used-percent": "80.0",
    "x-codex-secondary-reset-at": "1704074400",
    "x-codex-credits-has-credits": "true",
    "x-codex-credits-unlimited": "false",
    "x-codex-credits-balance": "10.00",
  }
}

///|
test "parse maps header families onto windows with seconds converted" {
  let readings = parse_codex_quota_headers(
    codex_headers_full(),
    fetched_at_ms=500L,
  )
  assert_eq(readings.length(), 3)
  assert_eq(readings[0].window, @devkit.QuotaWindow::FiveHours)
  assert_eq(readings[0].used_percent, Some(12.5))
  assert_eq(readings[0].reset_at_ms, Some(1704069000000L))
  assert_eq(readings[0].fetched_at_ms, 500L)
  assert_eq(readings[1].window, @devkit.QuotaWindow::Weekly)
  assert_eq(readings[1].used_percent, Some(80.0))
  assert_eq(readings[1].reset_at_ms, Some(1704074400000L))
  assert_eq(readings[2].window, @devkit.QuotaWindow::Balance)
  assert_eq(readings[2].amount, Some(("10.00", "credits")))
  assert_eq(readings[2].available, Some(true))
  assert_eq(readings[2].used_percent, None)
}

///|
test "parse skips families without a used-percent header" {
  let headers : @http.Headers = {
    "x-codex-primary-window-minutes": "300",
    "x-codex-credits-unlimited": "true",
  }
  let readings = parse_codex_quota_headers(headers, fetched_at_ms=1L)
  assert_eq(readings.length(), 0)
}

///|
test "parse tolerates malformed values by omitting them" {
  let headers : @http.Headers = {
    "x-codex-primary-used-percent": "not-a-number",
    "x-codex-secondary-used-percent": "41",
    "x-codex-secondary-reset-at": "soon",
    "x-codex-credits-has-credits": "yes",
  }
  let readings = parse_codex_quota_headers(headers, fetched_at_ms=1L)
  // secondary percentage survives; its reset does not. credits with an
  // unknown boolean vocabulary is skipped entirely.
  assert_eq(readings.length(), 1)
  assert_eq(readings[0].window, @devkit.QuotaWindow::Weekly)
  assert_eq(readings[0].used_percent, Some(41.0))
  assert_eq(readings[0].reset_at_ms, None)
}

///|
async test "tracker replays the latest snapshot and errors before capture" {
  let tracker = CodexQuotaTracker(now_ms=fn() { 42L })
  guard @devkit.QuotaSource::read(tracker) is Err(reason) else {
    fail("expected read to be unavailable before any capture")
  }
  assert_true(reason.contains("no Codex quota snapshot"))
  tracker.capture(codex_headers_full())
  guard tracker.snapshots() is [primary, weekly, credits] else {
    fail("expected three readings")
  }
  assert_eq(primary.fetched_at_ms, 42L)
  assert_eq(weekly.window, @devkit.QuotaWindow::Weekly)
  assert_eq(credits.available, Some(true))
  // A response without quota headers leaves the snapshot untouched.
  tracker.capture({ "content-type": "text/event-stream" })
  guard @devkit.QuotaSource::read(tracker) is Ok(readings) else {
    fail("expected the previous snapshot to survive")
  }
  assert_eq(readings.length(), 3)
  assert_eq(readings[0].fetched_at_ms, 42L)
}
