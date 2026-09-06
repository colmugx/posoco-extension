///|
/// Codex usage endpoint probe (wham/usage).
///
/// The ChatGPT backend states account usage beside the codex backend:
/// GET {backend-api}/wham/usage with the same OAuth bearer and account
/// headers a chat request carries. It answers the authoritative windows
/// (plan type, 5-hour, weekly, credits) without spending a model request —
/// the usage endpoint community tooling polls when no model traffic has
/// refreshed the response-header snapshot. The shape is provider-owned and
/// every field is optional; absent fields simply produce no reading.

///|
/// The usage endpoint lives beside the codex API base, not under it:
/// `https://chatgpt.com/backend-api/codex` → `.../backend-api/wham/usage`.
pub fn codex_usage_url(codex_api_base : String) -> String {
  let mut clean = codex_api_base
  while clean.has_suffix("/") {
    clean = clean.sub(end=clean.length() - 1).to_owned()
  }
  let base = match clean.strip_suffix("/codex") {
    Some(value) => value.to_owned()
    None => clean
  }
  base + "/wham/usage"
}

///|
/// One usage window states a duration; plans temporarily expose only the
/// weekly window in the primary slot, so label by duration (the number
/// Codex's own UI pairs) and keep the slot name only as a fallback.
fn codex_usage_window_label(
  window : Map[String, Json],
  fallback : String,
) -> String {
  match window.get("limit_window_seconds") {
    Some(Json::Number(seconds, ..)) => {
      let minutes = seconds.to_int() / 60
      if minutes == 300 {
        "5h"
      } else if minutes == 10080 {
        "weekly"
      } else {
        fallback + "(\{minutes}m)"
      }
    }
    _ => fallback
  }
}

///|
/// Map one usage window onto a reading. `reset_at` is absolute unix seconds;
/// when the provider states only `reset_after_seconds`, anchor it to the
/// fetch time. A window without a percentage or a reset time states nothing
/// actionable and is skipped.
fn codex_usage_window_reading(
  window : Map[String, Json],
  fallback_label : String,
  fetched_at_ms : Int64,
) -> @devkit.QuotaReading? {
  let used_percent = match window.get("used_percent") {
    Some(Json::Number(value, ..)) => Some(value)
    _ => None
  }
  let reset_at_ms = match window.get("reset_at") {
    Some(Json::Number(value, ..)) => Some(value.to_int().to_int64() * 1000L)
    _ =>
      match window.get("reset_after_seconds") {
        Some(Json::Number(value, ..)) =>
          Some(fetched_at_ms + value.to_int().to_int64() * 1000L)
        _ => None
      }
  }
  if used_percent is None && reset_at_ms is None {
    return None
  }
  Some({
    window: codex_usage_window_label(window, fallback_label),
    used_percent,
    amount: None,
    available: None,
    reset_at_ms,
    fetched_at_ms,
  })
}

///|
/// Parse a wham/usage response without performing I/O. Windows are keyed by
/// slot (`primary_window` / `secondary_window`); credits ride the balance
/// vocabulary the header capture already uses.
pub fn parse_codex_usage(
  payload : Json,
  fetched_at_ms~ : Int64,
) -> Result[Array[@devkit.QuotaReading], String] {
  let root = match payload {
    Json::Object(fields) => fields
    _ => return Err("Codex usage response must be an object")
  }
  let readings : Array[@devkit.QuotaReading] = []
  match root.get("rate_limit") {
    Some(Json::Object(rate_limit)) => {
      match rate_limit.get("primary_window") {
        Some(Json::Object(window)) =>
          match codex_usage_window_reading(window, "primary", fetched_at_ms) {
            Some(reading) => readings.push(reading)
            None => ()
          }
        _ => ()
      }
      match rate_limit.get("secondary_window") {
        Some(Json::Object(window)) =>
          match codex_usage_window_reading(window, "secondary", fetched_at_ms) {
            Some(reading) => readings.push(reading)
            None => ()
          }
        _ => ()
      }
    }
    _ => ()
  }
  match root.get("credits") {
    Some(Json::Object(credits)) => {
      let available = match credits.get("has_credits") {
        Some(Json::True) => Some(true)
        Some(Json::False) => Some(false)
        _ => None
      }
      let amount : (String, String)? = match credits.get("balance") {
        Some(Json::String(balance)) if balance != "" =>
          Some((balance, "credits"))
        _ => None
      }
      if available is Some(_) || amount is Some(_) {
        readings.push({
          window: "balance",
          used_percent: None,
          amount,
          available,
          reset_at_ms: None,
          fetched_at_ms,
        })
      }
    }
    _ => ()
  }
  Ok(readings)
}

///|
/// Probe the usage endpoint through the shared models transport (same
/// bearer + account header shape, same timeout). Errors surface as `Err`
/// strings — callers treat the probe as strictly best-effort.
pub async fn fetch_codex_usage_with_transport(
  transport : &OpenAIModelsHttpTransport,
  codex_api_base : String,
  access_token : String,
  account_id : String,
  now_ms? : () -> Int64 = fn() { @async.now() },
) -> Result[Array[@devkit.QuotaReading], String] {
  if account_id.length() == 0 {
    return Err("Codex usage request requires chatgpt-account-id metadata")
  }
  let headers : Map[String, String] = Map::from_array([
    ("Authorization", "Bearer " + access_token),
    ("Accept", "application/json"),
    ("chatgpt-account-id", account_id),
    ("originator", identity_originator),
    ("User-Agent", identity_user_agent_now()),
  ])
  let response = transport.get(codex_usage_url(codex_api_base), headers) catch {
    err => return Err("Codex usage request failed: " + err.to_string())
  }
  if response.status < 200 || response.status >= 300 {
    return Err(
      "Codex usage HTTP status: \{response.status}, body_chars=\{response.body.length()}",
    )
  }
  let payload : Json = @json.parse(response.body) catch {
    _ => return Err("Codex usage response JSON parse failure")
  }
  parse_codex_usage(payload, fetched_at_ms=now_ms())
}
