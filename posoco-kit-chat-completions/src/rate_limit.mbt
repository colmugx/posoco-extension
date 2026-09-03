///|
/// Shared quota-verdict classification for OpenAI Chat Completions–style
/// providers.
///
/// Coding-plan providers answer quota exhaustion with a throttling verdict,
/// but both the HTTP status and the reset hint's carrier differ per provider:
/// most use 429, Kimi's coding plan answers 403 ("You've reached your 5-hour
/// usage limit"); OpenAI/Codex puts `resets_at` (epoch seconds) and
/// `resets_in_seconds` in the error JSON; z.ai/bigmodel puts the flush time
/// inside the human message text ("Your limit will reset at 2026-08-21
/// 15:04:16"); generic gateways expose only a `retry_after`. This module
/// unifies those shapes into the typed `@posoco.RateLimitInfo`, so a
/// ModelPort raises `ModelError::RateLimited` instead of string-matching
/// `Transport`.
///
/// Status alone cannot gate the verdict (a 403 is usually an auth failure),
/// so non-429 bodies classify only when their phrasing reads as a quota
/// verdict. Transient 429s (z.ai 1302 concurrency, 1305 overload) carry no
/// reset time; they still classify as RateLimited with `reset_at_ms = None`
/// and the caller decides whether to back off briefly instead of scheduling.

///|
/// Days from civil date (Howard Hinnant's algorithm); pure integer math so
/// timezone-free timestamps convert without a datetime dependency.
fn days_from_civil(y : Int, m : Int, d : Int) -> Int64 {
  let yy = if m <= 2 { y - 1 } else { y }
  let era = if yy >= 0 { yy / 400 } else { (yy - 399) / 400 }
  let yoe = yy - era * 400
  let mp = (m + 9) % 12
  let doy = (153 * mp + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era.to_int64() * 146097L + doe.to_int64() - 719468L
}

///|
fn civil_to_epoch_ms(
  y : Int,
  m : Int,
  d : Int,
  hh : Int,
  mm : Int,
  ss : Int,
  tz_offset_minutes : Int,
) -> Int64? {
  if m < 1 ||
    m > 12 ||
    d < 1 ||
    d > 31 ||
    hh < 0 ||
    hh > 23 ||
    mm < 0 ||
    mm > 59 ||
    ss < 0 ||
    ss > 60 {
    return None
  }
  let days = days_from_civil(y, m, d)
  let secs = days * 86400L +
    hh.to_int64() * 3600L +
    mm.to_int64() * 60L +
    ss.to_int64() -
    tz_offset_minutes.to_int64() * 60L
  Some(secs * 1000L)
}

///|
fn is_digit_code(code : UInt16) -> Bool {
  code >= '0' && code <= '9'
}

///|
fn digit_value(code : UInt16) -> Int {
  (code - '0').to_int()
}

///|
fn scan_digits(text : String, i : Int, count : Int) -> (Int, Int)? {
  if i < 0 || i + count > text.length() {
    return None
  }
  let mut value = 0
  for k in 0..<count {
    let code = text[i + k]
    if !is_digit_code(code) {
      return None
    }
    value = value * 10 + digit_value(code)
  }
  Some((value, i + count))
}

///|
/// Scan a timezone offset starting at `i`. Recognized forms (case-insensitive
/// for the UTC marker): `Z`, `+08:00`, `-0800`, `+8`, `UTC+8`, `UTC+08:00`,
/// optionally wrapped in parentheses — z.ai emits `(UTC+8)` / `(UTC+08:00)`
/// directly after the seconds. Returns (offset_minutes, index after).
fn scan_tz_offset(text : String, i : Int) -> (Int, Int)? {
  let n = text.length()
  let mut j = i
  while j < n && text[j] == ' ' {
    j += 1
  }
  let mut wrapped = false
  if j < n && text[j] == '(' {
    wrapped = true
    j += 1
  }
  if j + 3 <= n {
    let c0 = text[j]
    let c1 = text[j + 1]
    let c2 = text[j + 2]
    if (c0 == 'U' || c0 == 'u') &&
      (c1 == 'T' || c1 == 't') &&
      (c2 == 'C' || c2 == 'c') {
      j += 3
    }
  }
  if j < n && text[j] == 'Z' && !wrapped {
    return Some((0, j + 1))
  }
  if j >= n || (text[j] != '+' && text[j] != '-') {
    return None
  }
  let sign = if text[j] == '+' { 1 } else { -1 }
  j += 1
  let (hh, after_hh) = match scan_digits(text, j, 2) {
    Some((two, next2)) => (two, next2)
    None =>
      match scan_digits(text, j, 1) {
        Some((one, next1)) => (one, next1)
        None => return None
      }
  }
  j = after_hh
  let mut mm = 0
  if j < n && text[j] == ':' {
    match scan_digits(text, j + 1, 2) {
      Some((value, next)) => {
        mm = value
        j = next
      }
      None => ()
    }
  } else if j + 2 <= n && is_digit_code(text[j]) && is_digit_code(text[j + 1]) {
    match scan_digits(text, j, 2) {
      Some((value, next)) => {
        mm = value
        j = next
      }
      None => ()
    }
  }
  if wrapped && j < n && text[j] == ')' {
    j += 1
  }
  if hh > 14 || mm > 59 {
    return None
  }
  Some((sign * (hh * 60 + mm), j))
}

///|
fn match_month_prefix(text : String, i : Int) -> Int? {
  if i + 3 > text.length() {
    return None
  }
  fn lower(code : UInt16) -> UInt16 {
    if code >= 'A' && code <= 'Z' {
      code - 'A' + 'a'
    } else {
      code
    }
  }
  let c0 = lower(text[i])
  let c1 = lower(text[i + 1])
  let c2 = lower(text[i + 2])
  if c0 == 'j' && c1 == 'a' && c2 == 'n' {
    return Some(1)
  }
  if c0 == 'f' && c1 == 'e' && c2 == 'b' {
    return Some(2)
  }
  if c0 == 'm' && c1 == 'a' && c2 == 'r' {
    return Some(3)
  }
  if c0 == 'a' && c1 == 'p' && c2 == 'r' {
    return Some(4)
  }
  if c0 == 'm' && c1 == 'a' && c2 == 'y' {
    return Some(5)
  }
  if c0 == 'j' && c1 == 'u' && c2 == 'n' {
    return Some(6)
  }
  if c0 == 'j' && c1 == 'u' && c2 == 'l' {
    return Some(7)
  }
  if c0 == 'a' && c1 == 'u' && c2 == 'g' {
    return Some(8)
  }
  if c0 == 's' && c1 == 'e' && c2 == 'p' {
    return Some(9)
  }
  if c0 == 'o' && c1 == 'c' && c2 == 't' {
    return Some(10)
  }
  if c0 == 'n' && c1 == 'o' && c2 == 'v' {
    return Some(11)
  }
  if c0 == 'd' && c1 == 'e' && c2 == 'c' {
    return Some(12)
  }
  None
}

///|
/// `YYYY-MM-DD[T ]HH:MM:SS[.fff]` plus optional timezone suffix.
fn try_iso_at(text : String, i : Int, default_tz : Int) -> (Int64, Int)? {
  let n = text.length()
  if i + 19 > n {
    return None
  }
  if text[i + 4] != '-' || text[i + 7] != '-' {
    return None
  }
  let sep = text[i + 10]
  if sep != 'T' && sep != 't' && sep != ' ' {
    return None
  }
  if text[i + 13] != ':' || text[i + 16] != ':' {
    return None
  }
  let (year, month, day, hh, mi, ss) = match
    (
      scan_digits(text, i, 4),
      scan_digits(text, i + 5, 2),
      scan_digits(text, i + 8, 2),
      scan_digits(text, i + 11, 2),
      scan_digits(text, i + 14, 2),
      scan_digits(text, i + 17, 2),
    ) {
    (
      Some((y, _)),
      Some((mo, _)),
      Some((d, _)),
      Some((h, _)),
      Some((mi2, _)),
      Some((s, _)),
    ) => (y, mo, d, h, mi2, s)
    _ => return None
  }
  let mut k = i + 19
  if k < n && text[k] == '.' {
    let mut frac_end = k + 1
    while frac_end < n && is_digit_code(text[frac_end]) {
      frac_end += 1
    }
    if frac_end > k + 1 {
      k = frac_end
    }
  }
  let (tz, after_tz) = match scan_tz_offset(text, k) {
    Some((offset, next)) => (offset, next)
    None => (default_tz, k)
  }
  let epoch_ms = match civil_to_epoch_ms(year, month, day, hh, mi, ss, tz) {
    Some(ms) => ms
    None => return None
  }
  Some((epoch_ms, after_tz))
}

///|
/// `Aug 13, 2026 at 15:52` / `… at 3:45pm` (Codex message style).
fn parse_english_date_at(
  text : String,
  i : Int,
  default_tz : Int,
) -> (Int64, Int)? {
  let n = text.length()
  let month = match match_month_prefix(text, i) {
    Some(m) => m
    None => return None
  }
  let j = i + 3
  if j >= n || text[j] != ' ' {
    return None
  }
  let (day, after_day) = match scan_digits(text, j + 1, 2) {
    Some((two, next2)) => (two, next2)
    None =>
      match scan_digits(text, j + 1, 1) {
        Some((one, next1)) => (one, next1)
        None => return None
      }
  }
  let mut k = after_day
  if k >= n || text[k] != ',' {
    return None
  }
  k += 1
  if k >= n || text[k] != ' ' {
    return None
  }
  let (year, after_year) = match scan_digits(text, k + 1, 4) {
    Some(pair) => pair
    None => return None
  }
  let mut m = after_year
  while m < n && text[m] == ' ' {
    m += 1
  }
  if m + 3 > n || text[m] != 'a' || text[m + 1] != 't' || text[m + 2] != ' ' {
    return None
  }
  m += 3
  while m < n && text[m] == ' ' {
    m += 1
  }
  let (hour_raw, after_hour) = match scan_digits(text, m, 2) {
    Some((two, next2)) => (two, next2)
    None =>
      match scan_digits(text, m, 1) {
        Some((one, next1)) => (one, next1)
        None => return None
      }
  }
  let mut p = after_hour
  if p >= n || text[p] != ':' {
    return None
  }
  let (minute, after_minute) = match scan_digits(text, p + 1, 2) {
    Some(pair) => pair
    None => return None
  }
  p = after_minute
  let mut second = 0
  if p < n && text[p] == ':' {
    match scan_digits(text, p + 1, 2) {
      Some((value, next)) => {
        second = value
        p = next
      }
      None => ()
    }
  }
  let mut hour = hour_raw
  let mut q = p
  if q < n && text[q] == ' ' {
    q += 1
  }
  if q + 1 < n && (text[q] == 'a' || text[q] == 'p') && text[q + 1] == 'm' {
    if text[q] == 'p' && hour_raw < 12 {
      hour = hour_raw + 12
    }
    if text[q] == 'a' && hour_raw == 12 {
      hour = 0
    }
    p = q + 2
  }
  let tz = match scan_tz_offset(text, p) {
    Some((offset, _)) => offset
    None => default_tz
  }
  let epoch_ms = match
    civil_to_epoch_ms(year, month, day, hour, minute, second, tz) {
    Some(ms) => ms
    None => return None
  }
  Some((epoch_ms, p))
}

///|
fn try_parse_absolute_at(
  text : String,
  i : Int,
  default_tz : Int,
) -> (Int64, Int)? {
  match try_iso_at(text, i, default_tz) {
    Some(result) => Some(result)
    None => parse_english_date_at(text, i, default_tz)
  }
}

///|
fn scan_relative_group(text : String, j : Int) -> (Int64, Int)? {
  let n = text.length()
  if j >= n || !is_digit_code(text[j]) {
    return None
  }
  let mut value : Int64 = 0L
  let mut k = j
  while k < n && is_digit_code(text[k]) {
    value = value * 10L + digit_value(text[k]).to_int64()
    k += 1
  }
  if k < n && text[k] == ' ' {
    k += 1
  }
  let unit_start = k
  while k < n && text[k] >= 'a' && text[k] <= 'z' {
    k += 1
  }
  if k == unit_start {
    return None
  }
  let unit = text.sub(start=unit_start, end=k).to_owned()
  let unit_ms : Int64 = if unit == "hour" || unit == "hours" || unit == "h" {
    3600000L
  } else if unit == "minute" ||
    unit == "minutes" ||
    unit == "min" ||
    unit == "m" {
    60000L
  } else if unit == "second" || unit == "seconds" || unit == "s" {
    1000L
  } else if unit == "day" || unit == "days" || unit == "d" {
    86400000L
  } else {
    return None
  }
  Some((value * unit_ms, k))
}

///|
/// "in 8 hours 30 minutes" / "in 13 minutes" / "in 2h 5m" anywhere in text.
fn try_parse_relative(text : String, now_ms~ : Int64) -> Int64? {
  let n = text.length()
  let mut i = 0
  while i + 3 < n {
    if text[i] == 'i' && text[i + 1] == 'n' && text[i + 2] == ' ' {
      let mut j = i + 3
      while j < n && text[j] == ' ' {
        j += 1
      }
      if j < n && is_digit_code(text[j]) {
        let mut total_ms : Int64 = 0L
        let mut groups = 0
        let mut k = j
        while groups < 3 {
          while k < n && text[k] == ' ' {
            k += 1
          }
          if k + 4 <= n &&
            text[k] == 'a' &&
            text[k + 1] == 'n' &&
            text[k + 2] == 'd' &&
            text[k + 3] == ' ' {
            k += 4
            while k < n && text[k] == ' ' {
              k += 1
            }
          }
          match scan_relative_group(text, k) {
            Some((group_ms, next)) => {
              total_ms += group_ms
              groups += 1
              k = next
            }
            None => break
          }
        }
        if groups > 0 {
          return Some(now_ms + total_ms)
        }
      }
    }
    i += 1
  }
  None
}

///|
/// A `Retry-After` value: delta-seconds ("120") or a timestamp string.
fn parse_retry_after_value(value : String, now_ms~ : Int64) -> Int64? {
  let trimmed = value.trim().to_owned()
  let mut all_digits = trimmed.length() > 0
  for i in 0..<trimmed.length() {
    if !is_digit_code(trimmed[i]) {
      all_digits = false
      break
    }
  }
  if all_digits {
    let mut secs : Int64 = 0L
    for i in 0..<trimmed.length() {
      secs = secs * 10L + digit_value(trimmed[i]).to_int64()
    }
    if secs >= 0 && secs <= 86400 * 14 {
      return Some(now_ms + secs * 1000L)
    }
    return None
  }
  parse_reset_timestamp(trimmed, now_ms~)
}

///|
/// Parse a provider-stated reset time out of free text. Supported shapes:
/// - `2026-08-21T15:04:16Z`, `2026-08-21 15:04:16`, `2026-08-21 15:04:16(UTC+8)`
/// - `Aug 13, 2026 at 15:52`, `Aug 13, 2026 at 3:45pm`
/// - relative: `in 8 hours 30 minutes`, `in 13 minutes`, `in 45 seconds`
///
/// `default_tz_offset_minutes~` applies only when the text carries no explicit
/// timezone (z.ai flush times are UTC+8; a generic gateway's are usually
/// UTC). Returns epoch milliseconds.
pub fn parse_reset_timestamp(
  text : String,
  default_tz_offset_minutes? : Int = 0,
  now_ms~ : Int64,
) -> Int64? {
  let n = text.length()
  let mut i = 0
  while i < n {
    let code = text[i]
    if is_digit_code(code) ||
      (code >= 'A' && code <= 'Z') ||
      (code >= 'a' && code <= 'z') {
      match try_parse_absolute_at(text, i, default_tz_offset_minutes) {
        Some((ms, _)) => return Some(ms)
        None => ()
      }
    }
    i += 1
  }
  try_parse_relative(text, now_ms~)
}

///|
fn lower_code(code : UInt16) -> UInt16 {
  if code >= 'A' && code <= 'Z' {
    code - 'A' + 'a'
  } else {
    code
  }
}

///|
/// Case-insensitive ASCII keyword match at `i`.
fn keyword_starts_at(text : String, i : Int, keyword : String) -> Bool {
  if i < 0 || i + keyword.length() > text.length() {
    return false
  }
  for k in 0..<keyword.length() {
    if lower_code(text[i + k]) != keyword[k] {
      return false
    }
  }
  true
}

///|
fn case_insensitive_contains(text : String, keyword : String) -> Bool {
  let n = text.length()
  let mut i = 0
  while i + keyword.length() <= n {
    if keyword_starts_at(text, i, keyword) {
      return true
    }
    i += 1
  }
  false
}

///|
/// Whether a non-429 error body reads as a quota verdict. Kimi answers
/// coding-plan quota exhaustion with 403, so status alone cannot gate: the
/// provider's own phrasing ("usage limit", "quota will reset") is the
/// discriminator; auth failures ("Invalid API key") never match.
fn body_carries_quota_verdict(text : String) -> Bool {
  let markers : Array[String] = [
    "usage limit", "usage_limit", "rate limit", "rate_limit", "quota",
  ]
  for marker in markers {
    if case_insensitive_contains(text, marker) {
      return true
    }
  }
  false
}

///|
/// Quota-window length named by the message ("5-hour usage limit",
/// "current 5-hour window ends", "3 day period"): `N` +
/// `hour|hours|minute|minutes|day|days` with a window keyword nearby. The
/// shape requires digits and a unit word, so token-count phrasing ("128k
/// context window") never matches.
fn window_length_ms(text : String) -> Int64? {
  let n = text.length()
  let mut i = 0
  while i < n {
    if !is_digit_code(text[i]) {
      i += 1
      continue
    }
    let mut value : Int64 = 0L
    while i < n && is_digit_code(text[i]) {
      value = value * 10L + digit_value(text[i]).to_int64()
      i += 1
    }
    if i < n && (text[i] == '-' || text[i] == ' ') {
      i += 1
    }
    let unit_start = i
    while i < n && text[i] >= 'a' && text[i] <= 'z' {
      i += 1
    }
    if i == unit_start {
      continue
    }
    let unit = text.sub(start=unit_start, end=i).to_owned()
    let unit_ms : Int64 = if unit == "hour" || unit == "hours" {
      3600000L
    } else if unit == "minute" || unit == "minutes" {
      60000L
    } else if unit == "day" || unit == "days" {
      86400000L
    } else {
      0L
    }
    if unit_ms > 0L && value > 0L && value <= 366L {
      let lookahead = if i + 24 < n { i + 24 } else { n }
      let mut j = i
      while j < lookahead {
        if keyword_starts_at(text, j, "window") ||
          keyword_starts_at(text, j, "usage limit") ||
          keyword_starts_at(text, j, "period") {
          return Some(value * unit_ms)
        }
        j += 1
      }
    }
  }
  None
}

///|
/// Window-length fallback for verdicts that name the window but no
/// timestamp: the true reset is at or before `now + length`, so scheduling
/// at that upper bound never resumes early.
fn parse_window_reset(text : String, now_ms~ : Int64) -> Int64? {
  match window_length_ms(text) {
    Some(length) => Some(now_ms + length)
    None => None
  }
}

///|
/// Epoch seconds, or milliseconds when the value is that large.
fn json_number_as_epoch_ms(value : Double) -> Int64? {
  if value < 0 || value > 4102444800000.0 { // year 2100
    return None
  }
  let seconds = if value >= 100000000000.0 { value / 1000.0 } else { value }
  let secs_int = seconds.to_int()
  if secs_int < 0 {
    return None
  }
  Some(secs_int.to_int64() * 1000L)
}

///|
fn json_field(container : Json, key : String) -> Json? {
  match container {
    Json::Object(fields) => fields.get(key)
    _ => None
  }
}

///|
fn json_string_value(json : Json) -> String? {
  match json {
    Json::String(value) => Some(value)
    _ => None
  }
}

///|
/// Render a provider error code that may arrive as a JSON string ("1308") or
/// number (1302) into its display string.
fn provider_code_string(json : Json) -> String? {
  match json {
    Json::String(value) => Some(value)
    Json::Number(value, ..) => {
      let as_int = value.to_int()
      if as_int.to_double() == value {
        Some("\{as_int}")
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn bounded_body_excerpt(text : String) -> String {
  let chars : Array[Char] = []
  let mut truncated = false
  for char in text {
    if chars.length() >= 160 {
      truncated = true
      break
    }
    match char {
      '\n' | '\r' => chars.push(' ')
      other => chars.push(other)
    }
  }
  let label = String::from_array(chars)
  if truncated {
    label + "…"
  } else {
    label
  }
}

///|
fn first_present(containers : Array[Json], keys : Array[String]) -> Json? {
  for container in containers {
    for key in keys {
      match json_field(container, key) {
        Some(value) => return Some(value)
        None => ()
      }
    }
  }
  None
}

///|
/// Classify an HTTP status + response body pair. Returns
/// `Some(ModelError::RateLimited(info))` for 429 verdicts and, like Kimi's
/// coding plan, 403 verdicts whose body phrasing reads as a quota wall;
/// `None` otherwise — the caller keeps its existing Transport formatting for
/// every other non-2xx status. `reset_at_ms` inside the info is `None` when
/// the provider stated no schedulable reset time (transient concurrency
/// limits); such verdicts are not schedulable and the caller should back off
/// or fail.
///
/// Extraction order (first hit wins):
/// 1. `resets_in_seconds` — relative seconds from now (OpenAI/Codex shape)
/// 2. `resets_at` / `reset_at` — epoch seconds (or milliseconds)
/// 3. `retry_after` / `retry-after` — seconds, or a timestamp string
/// 4. the `Retry-After` HTTP header, when the caller can read one (the
///    documented wait signal for Kimi/Moonshot verdicts, whose message text
///    carries no timestamp)
/// 5. the provider message text (z.ai "{next_flush_time}", Codex English
///    dates, relative "in N hours")
/// 6. the named quota-window length ("5-hour usage limit") — an upper bound
///    on the true reset time
///
/// Lookup covers both the nested `error` object and the top level. When the
/// body is not JSON at all, only paths 4-6 apply against the raw text.
pub fn classify_chat_completions_http_error(
  status : Int,
  body_text : String,
  default_tz_offset_minutes? : Int = 0,
  retry_after_header? : String? = None,
  now_ms~ : Int64,
) -> @posoco.ModelError? {
  let body : Json = @json.parse(body_text) catch { _ => Json::null() }
  let err : Json = match json_field(body, "error") {
    Some(inner) =>
      match inner {
        Json::Object(_) => inner
        _ => body
      }
    None => body
  }
  let scopes : Array[Json] = [err, body]
  let provider_code = match first_present(scopes, ["code", "type"]) {
    Some(code_json) =>
      match provider_code_string(code_json) {
        Some(code) => Some(code)
        None => None
      }
    None => None
  }
  let message = match first_present(scopes, ["message"]) {
    Some(message_json) =>
      match json_string_value(message_json) {
        Some(value) => value
        None => bounded_body_excerpt(body_text)
      }
    None => bounded_body_excerpt(body_text)
  }
  if status != 429 {
    // Kimi's coding plan answers quota exhaustion with 403; every other
    // non-429 (auth failures, provider bugs) keeps the caller's Transport
    // path unless the body itself reads as a quota verdict.
    let code_carries_quota = match provider_code {
      Some(code) => body_carries_quota_verdict(code)
      None => false
    }
    if status != 403 ||
      !(body_carries_quota_verdict(message) || code_carries_quota) {
      return None
    }
  }
  let mut reset_at_ms : Int64? = None
  match first_present(scopes, ["resets_in_seconds"]) {
    Some(Json::Number(value, ..)) => {
      let secs = value.to_int()
      if secs >= 0 && secs <= 86400 * 14 {
        reset_at_ms = Some(now_ms + secs.to_int64() * 1000L)
      }
    }
    _ => ()
  }
  if reset_at_ms is None {
    match first_present(scopes, ["resets_at", "reset_at"]) {
      Some(Json::Number(value, ..)) =>
        reset_at_ms = json_number_as_epoch_ms(value)
      Some(Json::String(value)) =>
        reset_at_ms = parse_reset_timestamp(
          value,
          default_tz_offset_minutes~,
          now_ms~,
        )
      _ => ()
    }
  }
  if reset_at_ms is None {
    match first_present(scopes, ["retry_after", "retry-after"]) {
      Some(Json::Number(value, ..)) => {
        let secs = value.to_int()
        if secs >= 0 && secs <= 86400 * 14 {
          reset_at_ms = Some(now_ms + secs.to_int64() * 1000L)
        }
      }
      Some(Json::String(value)) =>
        reset_at_ms = parse_reset_timestamp(
          value,
          default_tz_offset_minutes~,
          now_ms~,
        )
      _ => ()
    }
  }
  if reset_at_ms is None {
    match retry_after_header {
      Some(value) if value.trim().length() > 0 =>
        reset_at_ms = parse_retry_after_value(value, now_ms~)
      _ => ()
    }
  }
  if reset_at_ms is None && message.length() > 0 {
    reset_at_ms = parse_reset_timestamp(
      message,
      default_tz_offset_minutes~,
      now_ms~,
    )
    if reset_at_ms is None {
      // Kimi names the window ("5-hour usage limit") but no timestamp: the
      // window length is an upper bound on the true reset time.
      reset_at_ms = parse_window_reset(message, now_ms~)
    }
  }
  Some(
    @posoco.ModelError::RateLimited(@posoco.RateLimitInfo::{
      message,
      reset_at_ms,
      provider_code,
    }),
  )
}
