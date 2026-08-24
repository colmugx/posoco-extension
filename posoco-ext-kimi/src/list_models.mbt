///
/// Kimi model discovery for both API-key and managed OAuth endpoints.
///
/// The two endpoints share the provider-owned response contract used by
/// kimi-code: each model carries context length and thinking capability
/// metadata, with effort values nested under think_efforts.

///|
pub(all) struct KimiModelInfo {
  id : String
  display_name : String
  context_window : Int
  thinking_efforts : Array[String]
  default_effort : String?
  capabilities : Array[String]
}

///|
fn kimi_positive_int(
  value : Json,
  field : String,
) -> Int raise @posoco.ModelError {
  match value {
    Json::Number(number, ..) => {
      if number.is_nan() || number.is_inf() || number <= 0.0 {
        raise @posoco.ModelError::ResponseParse(
          "Kimi models " + field + " must be a positive integer",
        )
      }
      let integer = number.to_int()
      if integer <= 0 || integer.to_double() != number {
        raise @posoco.ModelError::ResponseParse(
          "Kimi models " + field + " must be a positive integer",
        )
      }
      integer
    }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "Kimi models " + field + " must be a number",
      )
  }
}

///|
fn kimi_optional_bool(
  fields : Map[String, Json],
  key : String,
) -> Bool raise @posoco.ModelError {
  match fields.get(key) {
    None => false
    Some(Json::True) => true
    Some(Json::False) => false
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "Kimi models " + key + " must be boolean",
      )
  }
}

///|
/// Parse the legacy flat effort declaration used by older Kimi model
/// endpoints.  A server-provided list is the source of truth; no effort names
/// are invented when the field is absent.
fn kimi_parse_flat_efforts(
  fields : Map[String, Json],
) -> (Array[String], String?) raise @posoco.ModelError {
  let support_efforts = match fields.get("support_efforts") {
    None => None
    Some(Json::Array(values)) => {
      let parsed : Array[String] = []
      for value in values {
        match value {
          Json::String(effort) if effort.length() > 0 => {
            if parsed.contains(effort) {
              raise @posoco.ModelError::ResponseParse(
                "Kimi models support_efforts contains duplicate effort",
              )
            }
            parsed.push(effort)
          }
          _ =>
            raise @posoco.ModelError::ResponseParse(
              "Kimi models support_efforts must contain non-empty strings",
            )
        }
      }
      Some(parsed)
    }
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "Kimi models support_efforts must be an array",
      )
  }
  let default_effort = match fields.get("default_effort") {
    None => None
    Some(Json::String(value)) if value.length() > 0 => Some(value)
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "Kimi models default_effort must not be empty",
      )
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "Kimi models default_effort must be a string",
      )
  }
  match (support_efforts, default_effort) {
    (None, None) => ([], None)
    (Some(values), None) => (values, None)
    (Some(values), Some(default_value)) => {
      if !values.contains(default_value) {
        raise @posoco.ModelError::ResponseParse(
          "Kimi models default_effort is not listed in support_efforts",
        )
      }
      (values, Some(default_value))
    }
    (None, Some(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "Kimi models default_effort requires support_efforts",
      )
  }
}

///|
fn kimi_thinking_mode(
  fields : Map[String, Json],
) -> String? raise @posoco.ModelError {
  match fields.get("supports_thinking_type") {
    None => None
    Some(Json::String(value)) if value == "only" ||
      value == "no" ||
      value == "both" => Some(value)
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "Kimi models supports_thinking_type must be only, no, or both",
      )
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "Kimi models supports_thinking_type must be a string",
      )
  }
}

///|
fn kimi_parse_efforts(
  fields : Map[String, Json],
) -> (Array[String], String?) raise @posoco.ModelError {
  match fields.get("think_efforts") {
    // The nested declaration is authoritative when present.
    None => kimi_parse_flat_efforts(fields)
    Some(Json::Object(effort_fields)) => {
      let support = match effort_fields.get("support") {
        Some(Json::True) => true
        Some(Json::False) => false
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "Kimi models think_efforts.support must be boolean",
          )
      }
      let valid = match effort_fields.get("valid_efforts") {
        Some(Json::Array(values)) => {
          let result : Array[String] = []
          for value in values {
            match value {
              Json::String(effort) if effort.length() > 0 => {
                if result.contains(effort) {
                  raise @posoco.ModelError::ResponseParse(
                    "Kimi models think_efforts.valid_efforts contains duplicate effort",
                  )
                }
                result.push(effort)
              }
              _ =>
                raise @posoco.ModelError::ResponseParse(
                  "Kimi models think_efforts.valid_efforts must contain non-empty strings",
                )
            }
          }
          result
        }
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "Kimi models think_efforts.valid_efforts must be an array",
          )
      }
      let default_effort = match effort_fields.get("default_effort") {
        Some(Json::String(value)) if value.length() > 0 => Some(value)
        Some(Json::String(_)) =>
          raise @posoco.ModelError::ResponseParse(
            "Kimi models think_efforts.default_effort must not be empty",
          )
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "Kimi models think_efforts.default_effort must be a string",
          )
        None => None
      }
      if support && valid.is_empty() {
        raise @posoco.ModelError::ResponseParse(
          "Kimi models think_efforts.support requires valid_efforts",
        )
      }
      if !support && !valid.is_empty() {
        raise @posoco.ModelError::ResponseParse(
          "Kimi models think_efforts.valid_efforts must be empty when support is false",
        )
      }
      match default_effort {
        Some(value) if !valid.contains(value) =>
          raise @posoco.ModelError::ResponseParse(
            "Kimi models think_efforts.default_effort is not listed in valid_efforts",
          )
        _ => ()
      }
      if support {
        (valid, default_effort)
      } else {
        ([], None)
      }
    }
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "Kimi models think_efforts must be an object",
      )
  }
}

///|
/// Determine whether the model advertises reasoning separately from the
/// effort list.  `supports_thinking_type` is authoritative when present;
/// otherwise preserve the provider's explicit boolean declaration.
fn kimi_supports_reasoning(
  fields : Map[String, Json],
  thinking_efforts : Array[String],
) -> Bool raise @posoco.ModelError {
  match fields.get("think_efforts") {
    // Nested provider metadata is authoritative over legacy booleans and
    // flat fields when present.
    Some(Json::Object(effort_fields)) =>
      match effort_fields.get("support") {
        Some(Json::True) => true
        Some(Json::False) => false
        _ =>
          raise @posoco.ModelError::ResponseParse(
            "Kimi models think_efforts.support must be boolean",
          )
      }
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "Kimi models think_efforts must be an object",
      )
    None =>
      match kimi_thinking_mode(fields) {
        Some("no") => false
        Some("only") => true
        Some("both") => true
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "Kimi models supports_thinking_type is invalid",
          )
        None =>
          kimi_optional_bool(fields, "supports_reasoning") ||
          !thinking_efforts.is_empty()
      }
  }
}

///|
/// Parse the provider-owned Kimi models envelope.
pub fn parse_kimi_models(
  payload : Json,
) -> Array[KimiModelInfo] raise @posoco.ModelError {
  let root = match payload {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "Kimi models response must be an object",
      )
  }
  let items = match root.get("data") {
    Some(Json::Array(values)) => values
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "Kimi models response data must be an array",
      )
  }
  let result : Array[KimiModelInfo] = []
  for item in items {
    let fields = match item {
      Json::Object(fields) => fields
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "Kimi models data item must be an object",
        )
    }
    let id = match fields.get("id") {
      Some(Json::String(value)) if value.length() > 0 => value
      Some(Json::String(_)) =>
        raise @posoco.ModelError::ResponseParse(
          "Kimi models item id must not be empty",
        )
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "Kimi models item is missing string id",
        )
    }
    let context_window = match fields.get("context_length") {
      Some(value) => kimi_positive_int(value, "context_length")
      None =>
        raise @posoco.ModelError::ResponseParse(
          "Kimi models item is missing context_length",
        )
    }
    let display_name = match fields.get("display_name") {
      None => id
      Some(Json::String(value)) if value.length() > 0 => value
      Some(Json::String(_)) =>
        raise @posoco.ModelError::ResponseParse(
          "Kimi models display_name must not be empty",
        )
      Some(_) =>
        raise @posoco.ModelError::ResponseParse(
          "Kimi models display_name must be a string",
        )
    }
    let (thinking_efforts, default_effort) = kimi_parse_efforts(fields)
    let supports_tool_use = kimi_optional_bool(fields, "supports_tool_use")
    let supports_reasoning = kimi_supports_reasoning(fields, thinking_efforts)
    let supports_image = kimi_optional_bool(fields, "supports_image_in")
    let supports_video = kimi_optional_bool(fields, "supports_video_in")
    let capabilities : Array[String] = ["chat", "streaming"]
    if supports_tool_use {
      capabilities.push("tool_use")
    }
    if supports_reasoning {
      capabilities.push("reasoning")
    }
    if supports_image {
      capabilities.push("image_in")
    }
    if supports_video {
      capabilities.push("video_in")
    }
    result.push(KimiModelInfo::{
      id,
      display_name,
      context_window,
      thinking_efforts,
      default_effort,
      capabilities,
    })
  }
  result
}

///|
fn kimi_models_url(base_url : String, endpoint_prefix : String) -> String {
  let mut clean = base_url
  while clean.has_suffix("/") {
    clean = clean.sub(end=clean.length() - 1).to_owned()
  }
  let mut prefix = endpoint_prefix
  while prefix.has_suffix("/") {
    prefix = prefix.sub(end=prefix.length() - 1).to_owned()
  }
  if prefix == "/" {
    prefix = ""
  }
  if prefix != "" && !prefix.has_prefix("/") {
    prefix = "/" + prefix
  }
  clean + prefix + "/models"
}

///|
/// Fetch and decode a live Kimi catalog. OAuth and API-key callers pass their
/// provider-selected base URL and opaque token; the host never builds this URL.
/// `identity_headers` carries the product identity set (User-Agent + X-Msh-*)
/// when the provider needs to impersonate kimi-code-cli for the managed
/// `/coding/v1/models` endpoint; it is merged under the Authorization/Accept
/// headers so the catalog wire contract stays authoritative.
pub async fn fetch_kimi_models(
  base_url : String,
  access_token : String,
  endpoint_prefix? : String = "",
  identity_headers? : Map[String, String] = Map::from_array([]),
) -> Array[KimiModelInfo] raise @posoco.ModelError {
  let headers : @http.Headers = Map([])
  for k, v in identity_headers {
    headers[k] = v
  }
  headers["Authorization"] = "Bearer " + access_token
  headers["Accept"] = "application/json"
  let (response, body_data) = @async.with_timeout(30000, () => {
    @http.get(kimi_models_url(base_url, endpoint_prefix), headers~)
  }) catch {
    @async.TimeoutError =>
      raise @posoco.ModelError::Transport(
        "Kimi list models request timed out (timeout_ms=30000)",
      )
    err =>
      raise @posoco.ModelError::Transport(
        "Kimi list models request failed: " + err.to_string(),
      )
  }
  if response.code < 200 || response.code >= 300 {
    raise @posoco.ModelError::Transport(
      "Kimi list models HTTP status: " +
      response.code.to_string() +
      ", body_bytes=" +
      body_data.binary().length().to_string(),
    )
  }
  let body_text = body_data.text() catch {
    err =>
      raise @posoco.ModelError::Transport(
        "Kimi list models body read failed: " + err.to_string(),
      )
  }
  let payload = @json.parse(body_text) catch {
    err =>
      raise @posoco.ModelError::ResponseParse(
        "Kimi list models JSON parse failed: " + err.to_string(),
      )
  }
  parse_kimi_models(payload)
}
