///
/// GLM Coding Plan quota probe — provider-stated usage percentages.
///
/// The coding-plan console exposes an account-level monitor endpoint next to
/// the chat endpoint. It states the authoritative numbers for each window
/// (5-hour, weekly, ...): nothing here is estimated from local token counts.
/// The endpoint shares the plan API key but, unlike the chat endpoint, wants
/// it as a bare `Authorization` value with no `Bearer` prefix.

///|
pub fn zai_coding_plan_quota_url(base_url : String) -> String {
  let clean = match base_url.strip_suffix("/") {
    Some(value) => value.to_owned()
    None => base_url
  }
  clean + "/api/monitor/usage/quota/limit"
}

///|
fn quota_json_string(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
fn quota_json_number(fields : Map[String, Json], key : String) -> Double? {
  match fields.get(key) {
    Some(Json::Number(value, ..)) => Some(value)
    _ => None
  }
}

///|
/// Map one `data.limits[]` entry onto the shared window vocabulary. The
/// provider distinguishes windows by `(type, unit, number)`: TOKENS_LIMIT
/// with unit=3/number=5 is the 5-hour window and unit=6/number=1 the weekly
/// one (as decoded by the community monitor tooling); TIME_LIMIT covers the
/// monthly MCP-tool allowance and stays `Other` rather than being guessed
/// into a typed slot.
fn zai_quota_window(
  limit_type : String?,
  unit : Double?,
  number : Double?,
) -> @devkit.QuotaWindow {
  match limit_type {
    Some("TOKENS_LIMIT") =>
      match (unit, number) {
        (Some(u), Some(n)) =>
          if u == 3.0 && n == 5.0 {
            @devkit.QuotaWindow::FiveHours
          } else if u == 6.0 && n == 1.0 {
            @devkit.QuotaWindow::Weekly
          } else {
            @devkit.QuotaWindow::Other("TOKENS_LIMIT(unit=\{u},number=\{n})")
          }
        _ => @devkit.QuotaWindow::Other("TOKENS_LIMIT")
      }
    Some(other) => @devkit.QuotaWindow::Other(other)
    None => @devkit.QuotaWindow::Other("unknown")
  }
}

///|
/// Parse a quota/limit response without performing I/O. Entries that carry
/// neither a percentage nor a reset time state nothing actionable and are
/// skipped instead of defaulted to zero.
pub fn parse_zai_coding_plan_quota(
  payload : Json,
  fetched_at_ms~ : Int64,
) -> Result[Array[@devkit.QuotaReading], String] {
  let root = match payload {
    Json::Object(fields) => fields
    _ => return Err("Z.ai quota response must be an object")
  }
  match root.get("success") {
    Some(Json::False) => {
      let msg = match quota_json_string(root, "msg") {
        Some(text) => text
        None => "unknown error"
      }
      return Err("Z.ai quota response reports failure: " + msg)
    }
    _ => ()
  }
  let data = match root.get("data") {
    Some(Json::Object(fields)) => fields
    _ => return Err("Z.ai quota response is missing object data")
  }
  let items = match data.get("limits") {
    Some(Json::Array(values)) => values
    _ => return Err("Z.ai quota response is missing array data.limits")
  }
  let readings : Array[@devkit.QuotaReading] = []
  for item in items {
    let fields = match item {
      Json::Object(fields) => fields
      _ => return Err("Z.ai quota limits item must be an object")
    }
    let used_percent = quota_json_number(fields, "percentage")
    let reset_at_ms = match quota_json_number(fields, "nextResetTime") {
      Some(ms) => Some(ms.to_int64())
      None => None
    }
    if used_percent is None && reset_at_ms is None {
      continue
    }
    readings.push({
      window: zai_quota_window(
        quota_json_string(fields, "type"),
        quota_json_number(fields, "unit"),
        quota_json_number(fields, "number"),
      ),
      used_percent,
      amount: None,
      available: None,
      reset_at_ms,
      fetched_at_ms,
    })
  }
  Ok(readings)
}

///|
/// Fetch the authoritative quota readings from the monitor endpoint.
pub async fn fetch_zai_coding_plan_quota(
  base_url : String,
  api_key : String,
  now_ms? : () -> Int64 = fn() { @async.now() },
) -> Result[Array[@devkit.QuotaReading], String] {
  let headers : @http.Headers = {
    "Authorization": api_key,
    "Accept": "application/json",
  }
  let fetched_at_ms = now_ms()
  let (response, body_data) = @async.with_timeout(10000, () => {
    @http.get(zai_coding_plan_quota_url(base_url), headers~)
  }) catch {
    @async.TimeoutError =>
      return Err("Z.ai quota request timed out (timeout_ms=10000)")
    err => return Err("Z.ai quota request failed: " + err.to_string())
  }
  if response.code < 200 || response.code >= 300 {
    return Err(
      "Z.ai quota HTTP status: " +
      response.code.to_string() +
      ", body_bytes=" +
      body_data.binary().length().to_string(),
    )
  }
  let body_text = body_data.text() catch {
    err => return Err("Z.ai quota body read failed: " + err.to_string())
  }
  let payload = @json.parse(body_text) catch {
    err => return Err("Z.ai quota JSON parse failed: " + err.to_string())
  }
  parse_zai_coding_plan_quota(payload, fetched_at_ms~)
}

///|
/// A `QuotaSource` backed by the GLM Coding Plan monitor endpoint.
pub(all) struct ZaiCodingPlanQuotaSource {
  base_url : String
  api_key : String
  now_ms : () -> Int64
}

///|
pub fn ZaiCodingPlanQuotaSource::ZaiCodingPlanQuotaSource(
  base_url? : String = "https://api.z.ai",
  api_key~ : String,
  now_ms? : () -> Int64 = fn() { @async.now() },
) -> ZaiCodingPlanQuotaSource {
  { base_url, api_key, now_ms, }
}

///|
pub impl @devkit.QuotaSource for ZaiCodingPlanQuotaSource with fn read(
  self : ZaiCodingPlanQuotaSource,
) -> Result[Array[@devkit.QuotaReading], String] {
  fetch_zai_coding_plan_quota(self.base_url, self.api_key, now_ms=self.now_ms)
}
