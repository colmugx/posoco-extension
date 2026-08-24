///|
test "parse_reset_timestamp: ISO with Z suffix" {
  let ms = parse_reset_timestamp(
    "Your limit will reset at 2026-08-21T15:04:16Z",
    now_ms=0L,
  )
  // 2026-08-21T15:04:16Z = 1787053456 seconds.
  debug_inspect(ms, content="Some(1787324656000)")
}

///|
test "parse_reset_timestamp: ISO space form defaults to configured tz" {
  let utc = parse_reset_timestamp(
    "Usage limit reached ... Resets at 2026-08-21 15:04:16",
    default_tz_offset_minutes=0,
    now_ms=0L,
  )
  debug_inspect(utc, content="Some(1787324656000)")
  let beijing = parse_reset_timestamp(
    "Usage limit reached ... Resets at 2026-08-21 15:04:16",
    default_tz_offset_minutes=480,
    now_ms=0L,
  )
  debug_inspect(beijing, content="Some(1787295856000)")
}

///|
test "parse_reset_timestamp: zai parenthesized UTC+8 suffix" {
  let ms = parse_reset_timestamp(
    "Usage limit reached for the past 5 hours. Resets at 2026-08-21 15:04:16(UTC+8).",
    now_ms=0L,
  )
  debug_inspect(ms, content="Some(1787295856000)")
  let alt = parse_reset_timestamp(
    "Your limit will reset at 2026-08-21 15:04:16 (UTC+08:00)",
    now_ms=0L,
  )
  debug_inspect(alt, content="Some(1787295856000)")
}

///|
test "parse_reset_timestamp: english date forms" {
  let h24 = parse_reset_timestamp(
    "You've hit your usage limit. try again after Aug 13, 2026 at 15:52",
    now_ms=0L,
  )
  debug_inspect(h24, content="Some(1786636320000)")
  let pm = parse_reset_timestamp(
    "You've hit your session limit · resets Aug 13, 2026 at 3:45pm",
    now_ms=0L,
  )
  debug_inspect(pm, content="Some(1786635900000)")
}

///|
test "parse_reset_timestamp: relative durations" {
  let hm = parse_reset_timestamp(
    "You've hit your usage limit. try again in 8 hours 30 minutes",
    now_ms=1000000L,
  )
  debug_inspect(hm, content="Some(31600000)")
  let m = parse_reset_timestamp("resets in 13 minutes", now_ms=5000L)
  debug_inspect(m, content="Some(785000)")
  let s = parse_reset_timestamp("in 45 seconds", now_ms=0L)
  debug_inspect(s, content="Some(45000)")
  let and_form = parse_reset_timestamp("in 1 hour and 30 minutes", now_ms=0L)
  debug_inspect(and_form, content="Some(5400000)")
}

///|
test "parse_reset_timestamp: unparseable text yields None" {
  debug_inspect(
    parse_reset_timestamp("Rate limit reached", now_ms=0L),
    content="None",
  )
  // Bare clock time without a date is not schedulable.
  debug_inspect(
    parse_reset_timestamp(
      "You've hit your session limit · resets 3:45pm",
      now_ms=0L,
    ),
    content="None",
  )
}

///|
test "classify: non-429 status returns None" {
  inspect(
    classify_chat_completions_http_error(
      500,
      "{\"error\":{\"message\":\"boom\"}}",
      now_ms=0L,
    ),
    content="None",
  )
}

///|
test "classify: codex structured body" {
  let body = "{\"error\":{\"type\":\"usage_limit_reached\",\"message\":\"The usage limit has been reached\",\"plan_type\":\"plus\",\"resets_at\":1778839243,\"resets_in_seconds\":756}}"
  let err = classify_chat_completions_http_error(429, body, now_ms=1000L)
  guard err is Some(@posoco.ModelError::RateLimited(info)) else {
    fail("expected RateLimited")
  }
  inspect(info.status, content="429")
  debug_inspect(info.provider_code, content="Some(\"usage_limit_reached\")")
  // resets_in_seconds wins over resets_at because it is checked first.
  debug_inspect(info.reset_at_ms, content="Some(757000)")
  inspect(info.message, content="The usage limit has been reached")
}

///|
test "classify: zai flush time in message text" {
  let body = "{\"error\":{\"code\":\"1308\",\"message\":\"Usage limit reached for 5 hour(s). Your limit will reset at 2026-08-21 15:04:16\"}}"
  let err = classify_chat_completions_http_error(
    429,
    body,
    default_tz_offset_minutes=480,
    now_ms=0L,
  )
  guard err is Some(@posoco.ModelError::RateLimited(info)) else {
    fail("expected RateLimited")
  }
  debug_inspect(info.provider_code, content="Some(\"1308\")")
  debug_inspect(info.reset_at_ms, content="Some(1787295856000)")
}

///|
test "classify: numeric zai code is rendered as string" {
  let body = "{\"error\":{\"code\":1302,\"message\":\"Rate limit reached for requests\"}}"
  let err = classify_chat_completions_http_error(429, body, now_ms=0L)
  guard err is Some(@posoco.ModelError::RateLimited(info)) else {
    fail("expected RateLimited")
  }
  debug_inspect(info.provider_code, content="Some(\"1302\")")
  // Transient concurrency verdict: no schedulable reset time.
  debug_inspect(info.reset_at_ms, content="None")
}

///|
test "classify: retry_after fallback and non-JSON body" {
  let retry = classify_chat_completions_http_error(
    429,
    "{\"error\":{\"message\":\"slow down\",\"retry_after\":30}}",
    now_ms=0L,
  )
  guard retry is Some(@posoco.ModelError::RateLimited(info)) else {
    fail("expected RateLimited")
  }
  debug_inspect(info.reset_at_ms, content="Some(30000)")
  // A non-JSON body still classifies as a rate-limit verdict, message only.
  let raw = classify_chat_completions_http_error(
    429,
    "plain gateway throttle",
    now_ms=0L,
  )
  guard raw is Some(@posoco.ModelError::RateLimited(raw_info)) else {
    fail("expected RateLimited")
  }
  inspect(raw_info.message, content="plain gateway throttle")
  debug_inspect(raw_info.reset_at_ms, content="None")
}
