///
/// DeepSeek balance probe — remaining funds, not a window quota.
///
/// DeepSeek has no subscription plan: the account spends a prepaid balance.
/// What it announces is therefore "how much money is left" and "can the
/// account still serve requests", never a used percentage or a reset time.
/// Both map onto the shared reading as `amount` and `available`; exhaustion
/// recovery is a manual top-up, so no reset is ever reported.

///|
pub fn deepseek_balance_url(base_url : String) -> String {
  let clean = match base_url.strip_suffix("/") {
    Some(value) => value.to_owned()
    None => base_url
  }
  clean + "/user/balance"
}

///|
fn balance_json_string(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
/// Parse a /user/balance response without performing I/O. Each currency
/// entry becomes one reading. Entries missing `currency` or `total_balance`
/// are skipped rather than failing the whole reading; with no usable entries
/// the availability-only reading still reports `is_available`.
pub fn parse_deepseek_balance(
  payload : Json,
  fetched_at_ms~ : Int64,
) -> Result[Array[@devkit.QuotaReading], String] {
  let root = match payload {
    Json::Object(fields) => fields
    _ => return Err("DeepSeek balance response must be an object")
  }
  let available : Bool? = match root.get("is_available") {
    Some(Json::True) => Some(true)
    Some(Json::False) => Some(false)
    _ => None
  }
  let readings : Array[@devkit.QuotaReading] = []
  match root.get("balance_infos") {
    Some(Json::Array(items)) =>
      for item in items {
        let fields = match item {
          Json::Object(fields) => fields
          _ => continue
        }
        let currency = match balance_json_string(fields, "currency") {
          Some(value) if value.length() > 0 => value
          _ => continue
        }
        let total = match balance_json_string(fields, "total_balance") {
          Some(value) if value.length() > 0 => value
          _ => continue
        }
        readings.push({
          window: @devkit.QuotaWindow::Balance,
          used_percent: None,
          amount: Some((total, currency)),
          available,
          reset_at_ms: None,
          fetched_at_ms,
        })
      }
    _ => ()
  }
  if readings.is_empty() {
    readings.push({
      window: @devkit.QuotaWindow::Balance,
      used_percent: None,
      amount: None,
      available,
      reset_at_ms: None,
      fetched_at_ms,
    })
  }
  Ok(readings)
}

///|
/// Fetch the balance reading from the platform endpoint.
pub async fn fetch_deepseek_balance(
  base_url : String,
  api_key : String,
  now_ms? : () -> Int64 = fn() { @async.now() },
) -> Result[Array[@devkit.QuotaReading], String] {
  let headers : @http.Headers = {
    "Authorization": "Bearer " + api_key,
    "Accept": "application/json",
  }
  let fetched_at_ms = now_ms()
  let (response, body_data) = @async.with_timeout(10000, () => {
    @http.get(deepseek_balance_url(base_url), headers~)
  }) catch {
    @async.TimeoutError =>
      return Err("DeepSeek balance request timed out (timeout_ms=10000)")
    err => return Err("DeepSeek balance request failed: " + err.to_string())
  }
  if response.code < 200 || response.code >= 300 {
    return Err(
      "DeepSeek balance HTTP status: " +
      response.code.to_string() +
      ", body_bytes=" +
      body_data.binary().length().to_string(),
    )
  }
  let body_text = body_data.text() catch {
    err => return Err("DeepSeek balance body read failed: " + err.to_string())
  }
  let payload = @json.parse(body_text) catch {
    err => return Err("DeepSeek balance JSON parse failed: " + err.to_string())
  }
  parse_deepseek_balance(payload, fetched_at_ms~)
}

///|
/// A `QuotaSource` backed by the DeepSeek /user/balance endpoint.
pub(all) struct DeepSeekBalanceSource {
  base_url : String
  api_key : String
  now_ms : () -> Int64
}

///|
pub fn DeepSeekBalanceSource::DeepSeekBalanceSource(
  base_url? : String = "https://api.deepseek.com",
  api_key~ : String,
  now_ms? : () -> Int64 = fn() { @async.now() },
) -> DeepSeekBalanceSource {
  { base_url, api_key, now_ms, }
}

///|
pub impl @devkit.QuotaSource for DeepSeekBalanceSource with fn read(
  self : DeepSeekBalanceSource,
) -> Result[Array[@devkit.QuotaReading], String] {
  fetch_deepseek_balance(self.base_url, self.api_key, now_ms=self.now_ms)
}
