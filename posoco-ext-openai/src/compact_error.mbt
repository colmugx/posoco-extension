///|
/// Compact-specific HTTP error diagnostics (W3): safe, bounded, parseable
/// `key=value` fields for the compact endpoint only — stage, status, the
/// provider error object's structural `code`/`param`/`type` and the
/// `x-request-id` response header. Arbitrary provider body text (including
/// `error.message`) is never echoed for compact, so no credential,
/// transcript, or encrypted payload can leak through the excerpt channel.

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
    Json::String(text) => compact_error_meta_text(text)
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
/// Compact HTTP failure message: safe structural fields first (parseable as
/// comma-separated key=value inside the wrapper), then the redacted body
/// size/category summary. Never an arbitrary provider excerpt.
fn format_compact_http_error(
  status : Int,
  body_summary : OpenAIErrorBodySummary,
  body_text : String?,
  request_id_header : String?,
) -> String {
  let (code, param, category) = compact_provider_error_meta(body_text)
  let request_id = match request_id_header {
    Some(value) => compact_error_meta_text(value)
    None => None
  }
  let buf = StringBuilder()
  buf.write_string(
    "OpenAI HTTP error (stage=compact_http_status, status=\{status}",
  )
  match code {
    Some(value) => buf.write_string(", code=\{value}")
    None => ()
  }
  match param {
    Some(value) => buf.write_string(", param=\{value}")
    None => ()
  }
  match category {
    Some(value) => buf.write_string(", category=\{value}")
    None => ()
  }
  match request_id {
    Some(value) => buf.write_string(", request_id=\{value}")
    None => ()
  }
  buf.write_string(", \{http_error_body_summary_text(body_summary)})")
  buf.to_string()
}
