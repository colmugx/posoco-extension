///|
/// External intelligence-efficiency metrics published by codex-reset-radar.
/// The radar is codex-community knowledge: every point is a stated benchmark
/// fact (model+effort IQ, average cost per run, passed/total problem counts),
/// never a local estimate. Entries cover non-OpenAI models too; filtering to
/// this provider's slots is the consumer's job.

///|
/// The live feed; `refresh=1` asks the worker to recompute rather than serve
/// a stale snapshot.
let intelligence_metrics_url : String = "https://codex-reset-radar.pages.dev/api/intelligence-efficiency-metrics?refresh=1"

///|
/// Required-field readers for one feed point. `Ok(None)` means the source
/// has not stated the field (`Json::Null` or an absent key — the marker of a
/// not-yet-measured placeholder point, which the point parser skips); a
/// stated but wrongly typed value is `Err`.
fn intelligence_metrics_point_string(
  fields : Map[String, Json],
  key : String,
) -> Result[String?, String] {
  match fields.get(key) {
    Some(Json::String(value)) if value.length() > 0 => Ok(Some(value))
    Some(Json::String(_)) =>
      Err("intelligence metrics point " + key + " must not be empty")
    Some(Json::Null) => Ok(None)
    Some(_) =>
      Err("intelligence metrics point " + key + " must be a non-empty string")
    None => Ok(None)
  }
}

///|
fn intelligence_metrics_point_number(
  fields : Map[String, Json],
  key : String,
) -> Result[Double?, String] {
  match fields.get(key) {
    Some(Json::Number(number, ..)) =>
      if number.is_nan() || number.is_inf() {
        Err("intelligence metrics point " + key + " must be a finite number")
      } else {
        Ok(Some(number))
      }
    Some(Json::Null) => Ok(None)
    Some(_) => Err("intelligence metrics point " + key + " must be a number")
    None => Ok(None)
  }
}

///|
fn intelligence_metrics_point_integer(
  fields : Map[String, Json],
  key : String,
) -> Result[Int?, String] {
  match fields.get(key) {
    Some(Json::Number(number, ..)) => {
      if number.is_nan() || number.is_inf() {
        return Err("intelligence metrics point " + key + " must be an integer")
      }
      let integer = number.to_int()
      if integer.to_double() != number {
        return Err("intelligence metrics point " + key + " must be an integer")
      }
      Ok(Some(integer))
    }
    Some(Json::Null) => Ok(None)
    Some(_) => Err("intelligence metrics point " + key + " must be a number")
    None => Ok(None)
  }
}

///|
/// Optional strictly-typed number: `Json::Number` (finite) → `Some`, absent
/// or `Json::Null` → `None` (the feed omits these fields on some entries,
/// e.g. deepseek points without `average_total_tokens`), anything else → Err.
fn intelligence_metrics_point_optional_number(
  fields : Map[String, Json],
  key : String,
) -> Result[Double?, String] {
  match fields.get(key) {
    Some(Json::Number(number, ..)) =>
      if number.is_nan() || number.is_inf() {
        Err("intelligence metrics point " + key + " must be a finite number")
      } else {
        Ok(Some(number))
      }
    Some(Json::Null) => Ok(None)
    Some(_) => Err("intelligence metrics point " + key + " must be a number")
    None => Ok(None)
  }
}

///|
/// Parse one feed point. Eight fields are consumed: six required and strictly
/// typed, plus the two optional `average_total_tokens`/`average_minutes`
/// (number → Some, absent or null → None, wrong type → Err); the other vendor
/// fields (including the deepseek `average_price_usd_by_band` bands) are
/// ignored.
///
/// A required field the source has not stated yet — `Json::Null` or absent —
/// marks a not-yet-measured placeholder entry (the live feed carries such
/// rows for models still being measured, every metric null with zero
/// samples), and the whole point is skipped: `Ok(None)`. A stated value with
/// the wrong type (a string where a number belongs, an empty-string `model`)
/// still fails the whole parse.
fn parse_intelligence_metrics_point(
  item : Json,
) -> Result[@devkit.MetricsPoint?, String] {
  let fields = match item {
    Json::Object(point_fields) => point_fields
    _ => return Err("intelligence metrics point must be an object")
  }
  let model = match intelligence_metrics_point_string(fields, "model") {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(reason) => return Err(reason)
  }
  let effort = match intelligence_metrics_point_string(fields, "effort") {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(reason) => return Err(reason)
  }
  let iq = match intelligence_metrics_point_number(fields, "iq") {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(reason) => return Err(reason)
  }
  let cost_usd = match
    intelligence_metrics_point_number(fields, "average_price_usd") {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(reason) => return Err(reason)
  }
  let passed = match intelligence_metrics_point_integer(fields, "passed") {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(reason) => return Err(reason)
  }
  let total = match intelligence_metrics_point_integer(fields, "total") {
    Ok(Some(value)) => value
    Ok(None) => return Ok(None)
    Err(reason) => return Err(reason)
  }
  let tokens = match
    intelligence_metrics_point_optional_number(fields, "average_total_tokens") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let minutes = match
    intelligence_metrics_point_optional_number(fields, "average_minutes") {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  Ok(
    Some(@devkit.MetricsPoint::{
      model,
      effort,
      iq,
      cost_usd,
      passed,
      total,
      tokens,
      minutes,
    }),
  )
}

///|
/// Parse the radar feed strictly about types and lenient about absence: the
/// top level must be an object carrying a `points` array, and each point
/// must carry the six required fields well typed when stated (the two
/// optional fields must be numbers when stated). A required field left
/// `Json::Null` or absent marks a not-yet-measured placeholder entry
/// (models still being measured on the live feed) and that point is skipped
/// silently — an all-skipped feed parses as an empty array. Wrong-typed
/// values still fail the whole parse, never a silent coercion, and a
/// failure never yields a partial array.
pub fn parse_intelligence_metrics(
  body : String,
) -> Result[Array[@devkit.MetricsPoint], String] {
  let payload : Json = @json.parse(body) catch {
    err =>
      return Err("intelligence metrics JSON parse failed: " + err.to_string())
  }
  let root = match payload {
    Json::Object(fields) => fields
    _ => return Err("intelligence metrics response must be an object")
  }
  let items = match root.get("points") {
    Some(Json::Array(values)) => values
    Some(_) => return Err("intelligence metrics points must be an array")
    None => return Err("intelligence metrics response is missing points")
  }
  let result : Array[@devkit.MetricsPoint] = []
  for item in items {
    match parse_intelligence_metrics_point(item) {
      Ok(Some(point)) => result.push(point)
      Ok(None) => ()
      Err(reason) => return Err(reason)
    }
  }
  Ok(result)
}

///|
/// Pull-style radar source: fetches the live feed through the shared models
/// transport on every read, so a pick command always sees fresh numbers.
priv struct RadarMetricsSource {
  transport : &OpenAIModelsHttpTransport
}

///|
impl @devkit.ModelMetricsSource for RadarMetricsSource with fn read(
  self : RadarMetricsSource,
) -> Result[Array[@devkit.MetricsPoint], String] {
  let headers : Map[String, String] = Map::from_array([])
  let response = self.transport.get(intelligence_metrics_url, headers) catch {
    err => return Err("intelligence metrics request failed: " + err.to_string())
  }
  if response.status != 200 {
    return Err("intelligence metrics HTTP " + response.status.to_string())
  }
  parse_intelligence_metrics(response.body)
}

///|
/// The radar source for factory registration. The feed is credential-free,
/// so the default models transport (5s timeout) carries it; registration
/// happens on every configured build/refresh (last write wins).
pub fn intelligence_metrics_source() -> &@devkit.ModelMetricsSource {
  let default_transport = DefaultOpenAIModelsHttpTransport::DefaultOpenAIModelsHttpTransport()
  let transport : &OpenAIModelsHttpTransport = default_transport
  let source = RadarMetricsSource::{ transport, }
  let borrowed : &@devkit.ModelMetricsSource = source
  borrowed
}
