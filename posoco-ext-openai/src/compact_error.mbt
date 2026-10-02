///|
/// Adapter-owned compact diagnostics. Core relays this safe bounded label
/// without interpreting its fields. Provider messages and response payloads
/// never enter the label.

///|
/// Upper bound for any single allowlisted diagnostic value.
let compact_error_meta_max_chars : Int = 96

///|
/// Only plainly printable provider metadata may enter compact diagnostics:
/// any quoting, whitespace, control character, separator, or non-ASCII
/// character discards the value entirely (the key is omitted, never
/// sanitized in place).
fn compact_error_meta_text(text : String) -> String? {
  if text.is_empty() || text.length() > compact_error_meta_max_chars {
    return None
  }
  for ch in text {
    let code = ch.to_int()
    let ok = (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
      (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
      (code >= '0'.to_int() && code <= '9'.to_int()) ||
      code == '.'.to_int() ||
      code == '_'.to_int() ||
      code == '-'.to_int() ||
      code == ':'.to_int() ||
      code == '/'.to_int() ||
      code == '['.to_int() ||
      code == ']'.to_int() ||
      code == '@'.to_int()
    if !ok {
      return None
    }
  }
  Some(text)
}

///|
fn compact_error_meta_value(value : Json) -> String? {
  match value {
    Json::String(text) if [
        "invalid_api_key", "invalid_request_error", "rate_limit_error", "rate_limit_exceeded",
        "insufficient_quota", "usage_limit_reached", "context_length_exceeded", "unsupported_parameter",
        "model_not_found", "server_error", "authentication_error", "permission_error",
        "model", "input", "tools", "instructions", "reasoning", "stream", "max_output_tokens",
        "temperature",
      ].contains(text) => Some(text)
    _ => None
  }
}

///|
/// The provider error object's structural fields: (code, param, category).
/// Bodies that are not JSON or carry no `error` object yield no metadata —
/// the size/category summary still identifies the body.
fn compact_provider_error_meta(
  body_text : String?,
) -> (String?, String?, String?) {
  let body = match body_text {
    Some(text) => text
    None => return (None, None, None)
  }
  let parsed : Result[Json, Error] = Ok(@json.parse(body)) catch { e => Err(e) }
  let provider_error : Map[String, Json]? = match parsed {
    Ok(Json::Object(fields)) =>
      match fields.get("error") {
        Some(Json::Object(error_fields)) => Some(error_fields)
        _ => None
      }
    _ => None
  }
  let code : String? = match provider_error {
    Some(error_fields) =>
      match error_fields.get("code") {
        Some(value) => compact_error_meta_value(value)
        None => None
      }
    None => None
  }
  let param : String? = match provider_error {
    Some(error_fields) =>
      match error_fields.get("param") {
        Some(value) => compact_error_meta_value(value)
        None => None
      }
    None => None
  }
  let category : String? = match provider_error {
    Some(error_fields) =>
      match error_fields.get("type") {
        Some(value) => compact_error_meta_value(value)
        None => None
      }
    None => None
  }
  (code, param, category)
}

///|
fn http_error_body_summary_text(summary : OpenAIErrorBodySummary) -> String {
  match summary {
    BodyChars(length) => "body_chars=\{length}, body_category=utf8"
    BodyBytesUtf8(length) => "body_bytes=\{length}, body_category=utf8"
    BodyBytesInvalidUtf8(length) =>
      "body_bytes=\{length}, body_category=invalid_utf8"
    BodyReadFailed => "body_category=read_failed"
    BodyUnavailable => "body_category=unavailable"
  }
}

///|
/// Prioritize request identity and provider verdict before optional context.
/// The adapter's aggregate bound leaves room for core's error wrappers under
/// the 512-character display limit; core need not parse or reorder fields.
fn format_compact_http_error(
  status : Int,
  body_summary : OpenAIErrorBodySummary,
  body_text : String?,
  request_id_header : String?,
  endpoint_kind~ : String,
  model~ : String,
) -> String {
  let (code, param, category) = compact_provider_error_meta(body_text)
  let request_id = match request_id_header {
    Some(value) if value.has_prefix("req_") => compact_error_meta_text(value)
    _ => None
  }
  let prefix = "OpenAI HTTP error (stage=compact_http_status, status=\{status}"
  let fields : Array[(String, String?)] = [
    ("request_id", request_id),
    ("code", code),
    ("param", param),
    ("category", category),
    ("endpoint", compact_error_meta_text(endpoint_kind)),
    ("model", compact_error_meta_text(model)),
  ]
  let buf = StringBuilder()
  buf.write_string(prefix)
  let mut remaining = 352 - prefix.length() - 1
  for (key, value) in fields {
    if value is Some(value) {
      let part = ", \{key}=\{value}"
      if part.length() <= remaining {
        buf.write_string(part)
        remaining -= part.length()
      }
    }
  }
  let summary = ", " + http_error_body_summary_text(body_summary)
  if summary.length() <= remaining {
    buf.write_string(summary)
  }
  buf.write_string(")")
  buf.to_string()
}
