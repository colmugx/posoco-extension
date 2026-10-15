///|
/// The OpenCode Go `/usage` payload, decoded.
///
/// `GET {base}/usage` (Bearer auth) answers the account's three usage
/// windows as percentages of their allowances: `rolling` is the 5-hour
/// window (20% of the model's monthly allowance per the vendor rule),
/// `weekly` 50%, `monthly` 100%. The endpoint takes no model parameter, so
/// its percentages describe the account, never the selected model. It
/// publishes no dollar balance and no plan tier — both stay undiscoverable
/// by design, and nothing here invents them.
pub(all) struct GoUsageWindow {
  percent : Double
  reset_at_ms : Int64?
  /// The endpoint's own `status`: "rate-limited" marks a window that is out.
  rate_limited : Bool
} derive(Eq, Debug)

///|
pub extend GoUsageWindow with Eq::{not_equal, equal}

///|
pub extend GoUsageWindow with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) struct GoUsage {
  /// The 5-hour rolling window (the payload's `rolling`).
  rolling : GoUsageWindow
  weekly : GoUsageWindow
  monthly : GoUsageWindow
  fetched_at_ms : Int64
} derive(Eq, Debug)

///|
pub extend GoUsage with Eq::{not_equal, equal}

///|
pub extend GoUsage with @moonbitlang/core/debug.Debug::{to_repr}

///|
fn go_usage_window(
  fields : Map[String, Json],
  label : String,
) -> Result[GoUsageWindow, String] {
  let percent = match fields.get("percent") {
    Some(Json::Number(n, ..)) =>
      if n >= 0.0 && n == n && n < 1.0e15 {
        n
      } else {
        return Err(
          "OpenCode Go usage percent for \{label} must be a non-negative number",
        )
      }
    _ =>
      return Err(
        "OpenCode Go usage window \{label} is missing a numeric percent",
      )
  }
  let reset_at_ms = match fields.get("resetsAt") {
    Some(Json::String(text)) =>
      @ratelimit.parse_reset_timestamp(text, now_ms=0L)
    _ => None
  }
  let rate_limited = match fields.get("status") {
    Some(Json::String("rate-limited")) => true
    Some(Json::String("ok")) => false
    // An absent status is the historical shape; the percent still stands.
    _ => false
  }
  Ok({ percent, reset_at_ms, rate_limited, })
}

///|
/// Parse a `/usage` response without performing I/O. Accepts both the live
/// envelope (`{usage:{rolling,weekly,monthly}}`) and the unwrapped root.
/// A malformed or missing window is a typed error — three `0%` rows would
/// read as a measurement the payload never made.
pub fn parse_go_usage(
  payload : Json,
  fetched_at_ms~ : Int64,
) -> Result[GoUsage, String] {
  let root = match payload {
    Json::Object(fields) => fields
    _ => return Err("OpenCode Go usage response must be an object")
  }
  let source = match root.get("usage") {
    Some(Json::Object(fields)) => fields
    Some(_) => return Err("OpenCode Go usage response usage must be an object")
    None => root
  }
  let rolling = match source.get("rolling") {
    Some(Json::Object(fields)) => go_usage_window(fields, "rolling")
    _ => return Err("OpenCode Go usage response is missing the rolling window")
  }
  let weekly = match source.get("weekly") {
    Some(Json::Object(fields)) => go_usage_window(fields, "weekly")
    _ => return Err("OpenCode Go usage response is missing the weekly window")
  }
  let monthly = match source.get("monthly") {
    Some(Json::Object(fields)) => go_usage_window(fields, "monthly")
    _ => return Err("OpenCode Go usage response is missing the monthly window")
  }
  match (rolling, weekly, monthly) {
    (Ok(rolling), Ok(weekly), Ok(monthly)) =>
      Ok({ rolling, weekly, monthly, fetched_at_ms, })
    (Err(e), _, _) | (_, Err(e), _) | (_, _, Err(e)) => Err(e)
  }
}
