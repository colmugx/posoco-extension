///|
test "parse maps each currency entry to a balance reading" {
  let payload : Json = {
    "is_available": true,
    "balance_infos": [
      {
        "currency": "CNY",
        "total_balance": "110.00",
        "granted_balance": "10.00",
        "topped_up_balance": "100.00",
      },
      {
        "currency": "USD",
        "total_balance": "5.25",
        "granted_balance": "0.00",
        "topped_up_balance": "5.25",
      },
    ],
  }
  guard parse_deepseek_balance(payload, fetched_at_ms=7L) is Ok(readings) else {
    fail("expected readings")
  }
  assert_eq(readings.length(), 2)
  assert_eq(readings[0].window, @devkit.QuotaWindow::Balance)
  assert_eq(readings[0].amount, Some(("110.00", "CNY")))
  assert_eq(readings[0].available, Some(true))
  assert_eq(readings[0].used_percent, None)
  assert_eq(readings[0].reset_at_ms, None)
  assert_eq(readings[0].fetched_at_ms, 7L)
  assert_eq(readings[1].amount, Some(("5.25", "USD")))
}

///|
test "parse carries exhaustion and unknown availability" {
  let exhausted : Json = {
    "is_available": false,
    "balance_infos": [
      {
        "currency": "CNY",
        "total_balance": "0.00",
        "granted_balance": "0.00",
        "topped_up_balance": "0.00",
      },
    ],
  }
  guard parse_deepseek_balance(exhausted, fetched_at_ms=1L) is Ok([reading]) else {
    fail("expected one reading")
  }
  assert_eq(reading.available, Some(false))
  assert_eq(reading.amount, Some(("0.00", "CNY")))
  // No balance_infos at all: the reading still reports availability only.
  let bare : Json = { "is_available": false }
  guard parse_deepseek_balance(bare, fetched_at_ms=1L) is Ok([fallback]) else {
    fail("expected a fallback reading")
  }
  assert_eq(fallback.amount, None)
  assert_eq(fallback.available, Some(false))
}

///|
test "parse skips malformed entries and rejects non-object payloads" {
  let payload : Json = {
    "is_available": true,
    "balance_infos": [
      { "currency": "", "total_balance": "1.00" },
      { "currency": "CNY" },
      "not-an-object",
      { "currency": "USD", "total_balance": "2.00" },
    ],
  }
  guard parse_deepseek_balance(payload, fetched_at_ms=1L) is Ok(readings) else {
    fail("expected readings")
  }
  assert_eq(readings.length(), 1)
  assert_eq(readings[0].amount, Some(("2.00", "USD")))
  let array_payload : Json = [1, 2]
  assert_true(parse_deepseek_balance(array_payload, fetched_at_ms=1L) is Err(_))
}

///|
test "balance url strips trailing slash and appends the platform path" {
  inspect(
    deepseek_balance_url("https://api.deepseek.com"),
    content="https://api.deepseek.com/user/balance",
  )
  inspect(
    deepseek_balance_url("http://localhost:8080/"),
    content="http://localhost:8080/user/balance",
  )
}
