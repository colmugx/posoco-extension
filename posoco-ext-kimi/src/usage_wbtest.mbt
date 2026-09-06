///|
fn usage_fixture() -> Json {
  {
    "usage": {
      "used": "40",
      "limit": "1000",
      "resetTime": "2026-08-03T05:20:51Z",
    },
    "limits": [
      {
        "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
        "detail": {
          "used": "1",
          "limit": "100",
          "resetTime": "2026-08-03T06:20:51Z",
        },
      },
    ],
    "boosterWallet": {
      "amount": 2500000,
      "amountLeft": 1234567,
      "monthlyChargeLimit": { "currency": "USD" },
    },
  }
}

///|
test "parse maps the weekly summary and the 5h window, ignoring the wallet" {
  let readings = parse_kimi_usage(usage_fixture(), fetched_at_ms=1000L)
  guard readings is Ok(values) else { fail("expected readings") }
  assert_eq(values.length(), 2)
  assert_eq(values[0].window, "weekly")
  assert_eq(values[0].used_percent, Some(4.0))
  assert_eq(values[0].reset_at_ms, Some(1785734451000L))
  assert_eq(values[0].fetched_at_ms, 1000L)
  assert_eq(values[0].amount, None)
  assert_eq(values[0].available, None)
  assert_eq(values[1].window, "5h")
  assert_eq(values[1].used_percent, Some(1.0))
  assert_eq(values[1].reset_at_ms, Some(1785738051000L))
  for reading in values {
    assert_true(reading.window != "balance")
  }
}

///|
test "boosterWallet produces no balance reading" {
  let readings = parse_kimi_usage(usage_fixture(), fetched_at_ms=1L)
  guard readings is Ok(values) else { fail("expected readings") }
  for reading in values {
    assert_true(reading.window != "balance")
    assert_eq(reading.amount, None)
  }
  let wallet_only : Json = {
    "boosterWallet": {
      "amount": 2500000,
      "amountLeft": 1234567,
      "monthlyChargeLimit": { "currency": "USD" },
    },
  }
  guard parse_kimi_usage(wallet_only, fetched_at_ms=1L) is Ok([]) else {
    fail("expected no readings from a wallet-only payload")
  }
}

///|
test "parse accepts decimal strings and JSON numbers alike" {
  let payload : Json = {
    "usage": { "used": 40, "limit": "1000" },
    "limits": [
      {
        "window": { "duration": "300", "timeUnit": "TIME_UNIT_MINUTE" },
        "detail": { "used": 1, "limit": 100 },
      },
    ],
    "boosterWallet": { "amountLeft": "2500000" },
  }
  let readings = parse_kimi_usage(payload, fetched_at_ms=1L)
  guard readings is Ok(values) else { fail("expected readings") }
  assert_eq(values.length(), 2)
  assert_eq(values[0].window, "weekly")
  assert_eq(values[0].used_percent, Some(4.0))
  assert_eq(values[1].window, "5h")
  assert_eq(values[1].used_percent, Some(1.0))
}

///|
test "parse skips rows that state no usable pair" {
  let payload : Json = {
    "usage": { "used": "40" },
    "limits": [
      {
        "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
        "detail": { "resetTime": "2026-08-03T06:20:51Z" },
      },
      {
        "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
        "detail": { "used": "2", "limit": "4" },
      },
    ],
  }
  let readings = parse_kimi_usage(payload, fetched_at_ms=1L)
  guard readings is Ok(values) else { fail("expected readings") }
  assert_eq(values.length(), 1)
  assert_eq(values[0].window, "5h")
  assert_eq(values[0].used_percent, Some(50.0))
  assert_eq(values[0].reset_at_ms, None)
}

///|
test "parse rejects non-object payloads" {
  let array_payload : Json = [1, 2]
  assert_true(parse_kimi_usage(array_payload, fetched_at_ms=1L) is Err(_))
  let text_payload : Json = "nope"
  assert_true(parse_kimi_usage(text_payload, fetched_at_ms=1L) is Err(_))
}

///|
test "reset times cover leap days, alternate keys and millisecond fractions" {
  let leap : Json = {
    "usage": { "used": "1", "limit": "2", "resetTime": "2024-02-29T00:00:00Z" },
  }
  guard parse_kimi_usage(leap, fetched_at_ms=1L) is Ok([reading]) else {
    fail("expected one reading")
  }
  assert_eq(reading.reset_at_ms, Some(1709164800000L))
  let alternate : Json = {
    "usage": { "used": "1", "limit": "2", "reset_at": "2026-08-03T05:20:51Z" },
    "limits": [
      {
        "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
        "detail": {
          "used": "1",
          "limit": "2",
          "resetAt": "2026-08-03T05:20:51Z",
        },
      },
    ],
  }
  guard parse_kimi_usage(alternate, fetched_at_ms=1L) is Ok([weekly, windowed]) else {
    fail("expected two readings")
  }
  assert_eq(weekly.reset_at_ms, Some(1785734451000L))
  assert_eq(windowed.reset_at_ms, Some(1785734451000L))
  let fractional : Json = {
    "usage": {
      "used": "1",
      "limit": "2",
      "resetTime": "2026-08-03T05:20:51.250Z",
    },
  }
  guard parse_kimi_usage(fractional, fetched_at_ms=1L) is Ok([reading]) else {
    fail("expected one reading")
  }
  // Fractional seconds are accepted but truncated: sub-second precision is
  // meaningless for quota resets.
  assert_eq(reading.reset_at_ms, Some(1785734451000L))
  let missing : Json = { "usage": { "used": "1", "limit": "2" } }
  guard parse_kimi_usage(missing, fetched_at_ms=1L) is Ok([reading]) else {
    fail("expected one reading")
  }
  assert_eq(reading.reset_at_ms, None)
}

///|
test "unmapped windows keep their raw duration and unit" {
  let payload : Json = {
    "limits": [
      {
        "window": { "duration": 5, "timeUnit": "TIME_UNIT_HOUR" },
        "detail": { "used": "1", "limit": "4" },
      },
      { "detail": { "used": "1", "limit": "4" } },
    ],
  }
  let readings = parse_kimi_usage(payload, fetched_at_ms=1L)
  guard readings is Ok(values) else { fail("expected readings") }
  assert_eq(values.length(), 2)
  assert_eq(values[0].window, "kimi(5TIME_UNIT_HOUR)")
  assert_eq(values[1].window, "kimi(unknown)")
}
