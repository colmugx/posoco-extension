///
/// Kimi For Coding /usages probe. Nothing is estimated: absent fields are
/// skipped, never defaulted.

///|
fn kimi_usage_url(base_url : String) -> String {
  let clean = match base_url.strip_suffix("/") {
    Some(value) => value.to_owned()
    None => base_url
  }
  clean + "/usages"
}

///|
fn kimi_usage_string(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
/// Kimi serializes counts as decimal strings in some responses and as JSON
/// numbers in others; both wire forms decode to the same value here.
fn kimi_usage_number(fields : Map[String, Json], key : String) -> Double? {
  match fields.get(key) {
    Some(Json::Number(value, ..)) => Some(value)
    Some(Json::String(raw)) => {
      let value : Double = @string.from_str(raw.trim()) catch {
        _ => return None
      }
      Some(value)
    }
    _ => None
  }
}

///|
/// Reset times: `resetTime`, with `reset_at`/`resetAt` accepted (kimi-cli
/// compat).
fn kimi_reset_at_ms(
  fields : Map[String, Json],
  fetched_at_ms~ : Int64,
) -> Int64? {
  for key in ["resetTime", "reset_at", "resetAt"] {
    match kimi_usage_string(fields, key) {
      Some(text) =>
        match @chatkit.parse_reset_timestamp(text, now_ms=fetched_at_ms) {
          Some(ms) => return Some(ms)
          None => ()
        }
      None => ()
    }
  }
  None
}

///|
fn kimi_used_percent(used : Double?, limit : Double?) -> Double? {
  match (used, limit) {
    (Some(used), Some(limit)) =>
      if limit == 0.0 || limit.is_nan() || limit.is_inf() {
        None
      } else {
        let percent = used * 100.0 / limit
        if percent.is_nan() || percent.is_inf() {
          None
        } else {
          Some(percent)
        }
      }
    _ => None
  }
}

///|
fn kimi_duration_text(duration : Double) -> String {
  if duration.is_nan() || duration.is_inf() {
    return duration.to_string()
  }
  let fixed = duration.to_int64()
  if fixed.to_double() == duration {
    fixed.to_string()
  } else {
    duration.to_string()
  }
}

///|
fn kimi_window_label(fields : Map[String, Json]) -> String {
  match fields.get("window") {
    Some(Json::Object(window)) =>
      match
        (
          kimi_usage_number(window, "duration"),
          kimi_usage_string(window, "timeUnit"),
        ) {
        (Some(duration), Some(unit)) =>
          if duration == 300.0 && unit == "TIME_UNIT_MINUTE" {
            "5h"
          } else {
            "kimi(" + kimi_duration_text(duration) + unit + ")"
          }
        _ => "kimi(unknown)"
      }
    _ => "kimi(unknown)"
  }
}

///|
pub fn parse_kimi_usage(
  payload : Json,
  fetched_at_ms~ : Int64,
) -> Result[Array[@devkit.QuotaReading], String] {
  let root = match payload {
    Json::Object(fields) => fields
    _ => return Err("Kimi usage response must be an object")
  }
  let readings : Array[@devkit.QuotaReading] = []
  match root.get("usage") {
    Some(Json::Object(fields)) =>
      match
        kimi_used_percent(
          kimi_usage_number(fields, "used"),
          kimi_usage_number(fields, "limit"),
        ) {
        Some(percent) =>
          readings.push({
            // The backend omits the window; it is the weekly limit.
            window: "weekly",
            used_percent: Some(percent),
            amount: None,
            available: None,
            reset_at_ms: kimi_reset_at_ms(fields, fetched_at_ms~),
            fetched_at_ms,
          })
        None => ()
      }
    _ => ()
  }
  match root.get("limits") {
    Some(Json::Array(items)) =>
      for item in items {
        let entry = match item {
          Json::Object(fields) => fields
          _ => continue
        }
        let detail = match entry.get("detail") {
          Some(Json::Object(fields)) => fields
          _ => continue
        }
        match
          kimi_used_percent(
            kimi_usage_number(detail, "used"),
            kimi_usage_number(detail, "limit"),
          ) {
          Some(percent) =>
            readings.push({
              window: kimi_window_label(entry),
              used_percent: Some(percent),
              amount: None,
              available: None,
              reset_at_ms: kimi_reset_at_ms(detail, fetched_at_ms~),
              fetched_at_ms,
            })
          None => continue
        }
      }
    _ => ()
  }
  Ok(readings)
}

///|
/// Failure diagnostics are redacted (status + body length), never the body.
async fn fetch_kimi_usage(
  base_url : String,
  access_token : String,
  now_ms? : () -> Int64 = fn() { @async.now() },
) -> Result[Array[@devkit.QuotaReading], String] {
  let headers : @http.Headers = {
    "Authorization": "Bearer " + access_token,
    "Accept": "application/json",
  }
  let fetched_at_ms = now_ms()
  let (response, body_data) = @async.with_timeout(10000, () => {
    @http.get(kimi_usage_url(base_url), headers~)
  }) catch {
    @async.TimeoutError =>
      return Err("Kimi usage request timed out (timeout_ms=10000)")
    err => return Err("Kimi usage request failed: " + err.to_string())
  }
  if response.code < 200 || response.code >= 300 {
    return Err(
      "Kimi usage HTTP status: " +
      response.code.to_string() +
      ", body_bytes=" +
      body_data.binary().length().to_string(),
    )
  }
  let body_text = body_data.text() catch {
    err => return Err("Kimi usage body read failed: " + err.to_string())
  }
  let payload = @json.parse(body_text) catch {
    err => return Err("Kimi usage JSON parse failed: " + err.to_string())
  }
  parse_kimi_usage(payload, fetched_at_ms~)
}

///|
/// OAuth-only: the API-key Open Platform has no /usages endpoint.
pub(all) struct KimiUsageSource {
  access_token : String
  base_url : String
  now_ms : () -> Int64
}

///|
pub fn KimiUsageSource::KimiUsageSource(
  access_token~ : String,
  base_url? : String = kimi_oauth_api_base(),
  now_ms? : () -> Int64 = fn() { @async.now() },
) -> KimiUsageSource {
  { access_token, base_url, now_ms, }
}

///|
pub impl @devkit.QuotaSource for KimiUsageSource with fn read(
  self : KimiUsageSource,
) -> Result[Array[@devkit.QuotaReading], String] {
  fetch_kimi_usage(self.base_url, self.access_token, now_ms=self.now_ms)
}
