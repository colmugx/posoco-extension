///|
/// Native+wasm+js: moonbitlang/async/http (`@http`) is unavailable on wasm-gc.
///
/// Live OpenCode Go reads: the `/models` listing (same envelope as the zen
/// plane) and the `/usage` three-window quota, plus the pull-style
/// QuotaSource the factory registers under the provider id.

///|
pub fn go_usage_url(base_url : String) -> String {
  let clean = match base_url.strip_suffix("/") {
    Some(value) => value.to_owned()
    None => base_url
  }
  clean + "/usage"
}

///|
/// Fetch and decode the live `/usage` reading. A Zen key on this endpoint
/// answers `403 EntitlementError` — surfaced verbatim so a misconfigured
/// credential is diagnosable, never rendered as fake zero-percent windows.
pub async fn fetch_go_usage(
  base_url : String,
  api_key : String,
  now_ms~ : () -> Int64 = fn() { @async.now() },
) -> Result[GoUsage, String] {
  let headers : @http.Headers = {
    "Authorization": "Bearer " + api_key,
    "Accept": "application/json",
  }
  let fetched_at_ms = now_ms()
  let (response, body_data) = @async.with_timeout(10000, () => {
    @http.get(go_usage_url(base_url), headers~)
  }) catch {
    @async.TimeoutError =>
      return Err("OpenCode Go usage request timed out (timeout_ms=10000)")
    err => return Err("OpenCode Go usage request failed: " + err.to_string())
  }
  if response.code < 200 || response.code >= 300 {
    let detail = body_data.text() catch {
      _ => "body_bytes=\{body_data.binary().length()}"
    }
    return Err(
      "OpenCode Go usage HTTP status: \{response.code}, body=\{detail}",
    )
  }
  let body_text = body_data.text() catch {
    err => return Err("OpenCode Go usage body read failed: " + err.to_string())
  }
  let payload = @json.parse(body_text) catch {
    err => return Err("OpenCode Go usage JSON parse failed: " + err.to_string())
  }
  parse_go_usage(payload, fetched_at_ms~)
}

///|
/// A `QuotaSource` backed by the live Go `/usage` endpoint: one reading per
/// window in the vendor's own vocabulary — `5h` (the payload's rolling
/// window), `weekly`, `monthly` — with the endpoint's percentage, its reset
/// time, and its own rate-limited verdict as `available`.
pub(all) struct GoUsageQuotaSource {
  base_url : String
  api_key : String
  now_ms : () -> Int64
}

///|
pub fn GoUsageQuotaSource::GoUsageQuotaSource(
  base_url~ : String,
  api_key~ : String,
  now_ms~ : () -> Int64 = fn() { @async.now() },
) -> GoUsageQuotaSource {
  { base_url, api_key, now_ms, }
}

///|
fn go_window_reading(
  window : String,
  data : GoUsageWindow,
  fetched_at_ms : Int64,
) -> @devkit.QuotaReading {
  {
    window,
    used_percent: Some(data.percent),
    amount: None,
    available: Some(!data.rate_limited),
    reset_at_ms: data.reset_at_ms,
    fetched_at_ms,
  }
}

///|
pub impl @devkit.QuotaSource for GoUsageQuotaSource with fn read(
  self : GoUsageQuotaSource,
) -> Result[Array[@devkit.QuotaReading], String] {
  let usage = fetch_go_usage(self.base_url, self.api_key, now_ms=self.now_ms)
  match usage {
    Err(message) => Err(message)
    Ok(usage) => {
      let readings : Array[@devkit.QuotaReading] = [
        go_window_reading("5h", usage.rolling, usage.fetched_at_ms),
        go_window_reading("weekly", usage.weekly, usage.fetched_at_ms),
        go_window_reading("monthly", usage.monthly, usage.fetched_at_ms),
      ]
      Ok(readings)
    }
  }
}

///|
pub extend GoUsageQuotaSource with @devkit.QuotaSource::{read}
