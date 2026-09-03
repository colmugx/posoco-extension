///|
fn quota_fixture() -> Json {
  {
    "success": true,
    "code": "0",
    "msg": "",
    "data": {
      "limits": [
        {
          "type": "TOKENS_LIMIT",
          "unit": 3,
          "number": 5,
          "percentage": 12.5,
          "total": 40000000,
          "nextResetTime": 1756900000000,
        },
        { "type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 87.5 },
        { "type": "TIME_LIMIT", "percentage": 40.0 },
        { "type": "TOKENS_LIMIT", "unit": 9, "number": 2 },
      ],
    },
  }
}

///|
test "parse maps windows and skips entries that state nothing" {
  let readings = parse_zai_coding_plan_quota(
    quota_fixture(),
    fetched_at_ms=1000L,
  )
  guard readings is Ok(values) else { fail("expected readings") }
  assert_eq(values.length(), 3)
  assert_eq(values[0].window, @devkit.QuotaWindow::FiveHours)
  assert_eq(values[0].used_percent, Some(12.5))
  assert_eq(values[0].reset_at_ms, Some(1756900000000L))
  assert_eq(values[0].fetched_at_ms, 1000L)
  assert_eq(values[1].window, @devkit.QuotaWindow::Weekly)
  assert_eq(values[1].reset_at_ms, None)
  assert_eq(values[2].window, @devkit.QuotaWindow::Other("TIME_LIMIT"))
  assert_eq(values[2].used_percent, Some(40.0))
}

///|
test "parse rejects failure envelopes and malformed shapes" {
  let failure : Json = { "success": false, "msg": "no auth" }
  guard parse_zai_coding_plan_quota(failure, fetched_at_ms=1L) is Err(reason) else {
    fail("expected failure envelope to be rejected")
  }
  assert_true(reason.contains("no auth"))
  let missing_data : Json = { "success": true }
  assert_true(
    parse_zai_coding_plan_quota(missing_data, fetched_at_ms=1L) is Err(_),
  )
  let array_payload : Json = [1, 2]
  assert_true(
    parse_zai_coding_plan_quota(array_payload, fetched_at_ms=1L) is Err(_),
  )
}

///|
test "parse keeps unmapped token windows as Other with the raw numbers" {
  let payload : Json = {
    "success": true,
    "data": {
      "limits": [
        { "type": "TOKENS_LIMIT", "unit": 9, "number": 2, "percentage": 1.0 },
      ],
    },
  }
  guard parse_zai_coding_plan_quota(payload, fetched_at_ms=1L) is Ok([reading]) else {
    fail("expected one reading")
  }
  guard reading.window is @devkit.QuotaWindow::Other(label) else {
    fail("expected an Other window")
  }
  assert_true(label.contains("TOKENS_LIMIT"))
  assert_true(label.contains("unit=9"))
  assert_true(label.contains("number=2"))
}

///|
test "quota url strips trailing slash and appends the monitor path" {
  inspect(
    zai_coding_plan_quota_url("https://api.z.ai"),
    content="https://api.z.ai/api/monitor/usage/quota/limit",
  )
  inspect(
    zai_coding_plan_quota_url("https://open.bigmodel.cn/"),
    content="https://open.bigmodel.cn/api/monitor/usage/quota/limit",
  )
}
