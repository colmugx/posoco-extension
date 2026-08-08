///|
/// Provider-owned model discovery for OpenAI API-key and ChatGPT/Codex OAuth
/// credentials.  The two endpoints intentionally have different response
/// schemas; never decode the Codex response through the OpenAI `data` parser.

///|
pub(all) struct OpenAIModelInfo {
  id : String
  display_name : String
}

///|
pub(all) struct CodexReasoningLevel {
  effort : String
  description : String
}

///|
pub(all) struct CodexModelInfo {
  slug : String
  display_name : String
  description : String?
  default_reasoning_level : String?
  supported_reasoning_levels : Array[CodexReasoningLevel]
  visibility : String
  supported_in_api : Bool
  priority : Int
  context_window : Int?
}

///|
/// Public GET seam for explicit model refresh.  Provider extensions own the
/// endpoint and headers; tests can inject a fake without opening a socket.
pub(all) struct OpenAIModelsHttpResponse {
  status : Int
  body : String
}

///|
pub(open) trait OpenAIModelsHttpTransport {
  async fn get(Self, url : String, headers : Map[String, String]) -> OpenAIModelsHttpResponse raise @posoco.ModelError
}

///|
pub(all) struct DefaultOpenAIModelsHttpTransport {}

///|
pub fn DefaultOpenAIModelsHttpTransport::DefaultOpenAIModelsHttpTransport() -> DefaultOpenAIModelsHttpTransport {
  DefaultOpenAIModelsHttpTransport::{  }
}

///|
/// Codex uses the client version as a request query parameter.  Keep this
/// provider-owned value aligned with the Codex CLI release shipped by the
/// extension; the current upstream release is 0.146.0.
pub fn openai_codex_models_client_version() -> String {
  "0.146.0"
}

///|
let openai_models_timeout_ms : Int = 5000

///|
pub impl OpenAIModelsHttpTransport for DefaultOpenAIModelsHttpTransport with fn get(
  _self : DefaultOpenAIModelsHttpTransport,
  url : String,
  headers : Map[String, String],
) -> OpenAIModelsHttpResponse raise @posoco.ModelError {
  @async.with_timeout(openai_models_timeout_ms, () => {
    let (response, body_data) = @http.get(url, headers~) catch {
      err =>
        raise @posoco.ModelError::Transport(
          "OpenAI models request failed: " + err.to_string(),
        )
    }
    let body = body_data.text() catch {
      err =>
        raise @posoco.ModelError::Transport(
          "OpenAI models response body read failed: " + err.to_string(),
        )
    }
    OpenAIModelsHttpResponse::{ status: response.code, body }
  }) catch {
    @async.TimeoutError =>
      raise @posoco.ModelError::Transport(
        "OpenAI models request timed out (timeout_ms=" +
        openai_models_timeout_ms.to_string() +
        ")",
      )
    err =>
      raise @posoco.ModelError::Transport(
        "OpenAI models request failed: " + err.to_string(),
      )
  }
}

///|
fn openai_models_url(base_url : String) -> String {
  let mut clean = base_url
  while clean.has_suffix("/") {
    clean = clean.sub(end=clean.length() - 1).to_owned()
  }
  clean + "/models"
}

///|
fn codex_models_url(base_url : String, client_version : String) -> String {
  openai_models_url(base_url) + "?client_version=" + client_version
}

///|
fn parse_positive_integer(
  value : Json,
  field : String,
) -> Int raise @posoco.ModelError {
  match value {
    Json::Number(number, ..) => {
      if number.is_nan() || number.is_inf() || number <= 0.0 {
        raise @posoco.ModelError::ResponseParse(
          "OpenAI models " + field + " must be a positive integer",
        )
      }
      let integer = number.to_int()
      if integer <= 0 || integer.to_double() != number {
        raise @posoco.ModelError::ResponseParse(
          "OpenAI models " + field + " must be a positive integer",
        )
      }
      integer
    }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI models " + field + " must be a number",
      )
  }
}

///|
fn parse_optional_positive_integer(
  fields : Map[String, Json],
  key : String,
) -> Int? raise @posoco.ModelError {
  match fields.get(key) {
    None | Some(Json::Null) => None
    Some(value) => Some(parse_positive_integer(value, key))
  }
}

///|
fn parse_optional_nonempty_string(
  fields : Map[String, Json],
  key : String,
) -> String? raise @posoco.ModelError {
  match fields.get(key) {
    None | Some(Json::Null) => None
    Some(Json::String(value)) if value.length() > 0 => Some(value)
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "Codex models " + key + " must not be empty",
      )
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "Codex models " + key + " must be a string",
      )
  }
}

///|
fn parse_required_nonempty_string(
  fields : Map[String, Json],
  key : String,
  prefix : String,
) -> String raise @posoco.ModelError {
  match fields.get(key) {
    Some(Json::String(value)) if value.length() > 0 => value
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        prefix + " " + key + " must not be empty",
      )
    _ =>
      raise @posoco.ModelError::ResponseParse(
        prefix + " " + key + " must be a non-empty string",
      )
  }
}

///|
fn parse_required_bool(
  fields : Map[String, Json],
  key : String,
  prefix : String,
) -> Bool raise @posoco.ModelError {
  match fields.get(key) {
    Some(Json::True) => true
    Some(Json::False) => false
    _ =>
      raise @posoco.ModelError::ResponseParse(
        prefix + " " + key + " must be boolean",
      )
  }
}

///|
fn parse_codex_reasoning_levels(
  fields : Map[String, Json],
) -> (Array[CodexReasoningLevel], String?) raise @posoco.ModelError {
  let levels = match fields.get("supported_reasoning_levels") {
    Some(Json::Array(values)) => values
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "Codex models supported_reasoning_levels must be an array",
      )
  }
  let result : Array[CodexReasoningLevel] = []
  for value in levels {
    let level = match value {
      Json::Object(level_fields) => level_fields
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "Codex models reasoning level must be an object",
        )
    }
    let effort = parse_required_nonempty_string(
      level, "effort", "Codex models reasoning level",
    )
    if result.any(fn(item) { item.effort == effort }) {
      raise @posoco.ModelError::ResponseParse(
        "Codex models supported_reasoning_levels contains duplicate effort",
      )
    }
    let description = parse_required_nonempty_string(
      level, "description", "Codex models reasoning level",
    )
    result.push(CodexReasoningLevel::{ effort, description })
  }
  let default_effort = parse_optional_nonempty_string(
    fields, "default_reasoning_level",
  )
  match default_effort {
    Some(value) if !result.any(fn(item) { item.effort == value }) =>
      raise @posoco.ModelError::ResponseParse(
        "Codex models default_reasoning_level is not supported",
      )
    _ => ()
  }
  (result, default_effort)
}

///|
/// Parse the standard OpenAI API-key envelope.  This parser only accepts the
/// `data[].id` protocol; it is deliberately not shared with Codex parsing.
pub fn parse_openai_models(
  payload : Json,
) -> Array[OpenAIModelInfo] raise @posoco.ModelError {
  let root = match payload {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI models response must be an object",
      )
  }
  match root.get("object") {
    Some(Json::String("list")) => ()
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI models response object must be list",
      )
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI models response object must be a string",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI models response is missing object",
      )
  }
  let items = match root.get("data") {
    Some(Json::Array(values)) => values
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI models response data must be an array",
      )
  }
  let result : Array[OpenAIModelInfo] = []
  for item in items {
    let fields = match item {
      Json::Object(fields) => fields
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "OpenAI models data item must be an object",
        )
    }
    let id = parse_required_nonempty_string(fields, "id", "OpenAI models item")
    let display_name = match fields.get("display_name") {
      None | Some(Json::Null) => id
      Some(Json::String(value)) if value.length() > 0 => value
      Some(Json::String(_)) =>
        raise @posoco.ModelError::ResponseParse(
          "OpenAI models item display_name must not be empty",
        )
      Some(_) =>
        raise @posoco.ModelError::ResponseParse(
          "OpenAI models item display_name must be a string",
        )
    }
    result.push(OpenAIModelInfo::{ id, display_name })
  }
  result
}

///|
/// Parse the ChatGPT/Codex `/models` envelope.  The response is provider
/// specific and carries server-declared reasoning levels in declaration order.
pub fn parse_codex_models(
  payload : Json,
) -> Array[CodexModelInfo] raise @posoco.ModelError {
  let root = match payload {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "Codex models response must be an object",
      )
  }
  let items = match root.get("models") {
    Some(Json::Array(values)) => values
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "Codex models response models must be an array",
      )
  }
  let result : Array[CodexModelInfo] = []
  for item in items {
    let fields = match item {
      Json::Object(fields) => fields
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "Codex models item must be an object",
        )
    }
    let slug = parse_required_nonempty_string(
      fields, "slug", "Codex models item",
    )
    let display_name = parse_required_nonempty_string(
      fields, "display_name", "Codex models item",
    )
    let description = parse_optional_nonempty_string(fields, "description")
    let (supported_reasoning_levels, default_reasoning_level) = parse_codex_reasoning_levels(
      fields,
    )
    let visibility = parse_required_nonempty_string(
      fields, "visibility", "Codex models item",
    )
    let supported_in_api = parse_required_bool(
      fields, "supported_in_api", "Codex models item",
    )
    let priority = match fields.get("priority") {
      Some(Json::Number(number, ..)) => {
        if number.is_nan() || number.is_inf() {
          raise @posoco.ModelError::ResponseParse(
            "Codex models item priority must be an integer",
          )
        }
        let integer = number.to_int()
        if integer.to_double() != number {
          raise @posoco.ModelError::ResponseParse(
            "Codex models item priority must be an integer",
          )
        }
        integer
      }
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "Codex models item priority must be a number",
        )
    }
    let context_window = parse_optional_positive_integer(
      fields, "context_window",
    )
    result.push(CodexModelInfo::{
      slug,
      display_name,
      description,
      default_reasoning_level,
      supported_reasoning_levels,
      visibility,
      supported_in_api,
      priority,
      context_window,
    })
  }
  result
}

///|
async fn fetch_models_with_transport(
  transport : &OpenAIModelsHttpTransport,
  url : String,
  headers : Map[String, String],
) -> Json raise @posoco.ModelError {
  let response = transport.get(url, headers)
  if response.status < 200 || response.status >= 300 {
    raise @posoco.ModelError::Transport(
      "OpenAI models HTTP status: " +
      response.status.to_string() +
      ", body_chars=" +
      response.body.length().to_string(),
    )
  }
  @json.parse(response.body) catch {
    err =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI models JSON parse failed: " + err.to_string(),
      )
  }
}

///|
/// Fetch standard OpenAI-compatible model metadata with an injected transport.
pub async fn fetch_openai_models_with_transport(
  transport : &OpenAIModelsHttpTransport,
  base_url : String,
  api_key : String,
) -> Array[OpenAIModelInfo] raise @posoco.ModelError {
  let headers : Map[String, String] = Map::from_array([
    ("Authorization", "Bearer " + api_key),
    ("Accept", "application/json"),
  ])
  let payload = fetch_models_with_transport(
    transport,
    openai_models_url(base_url),
    headers,
  )
  parse_openai_models(payload)
}

///|
/// Fetch Codex model metadata.  This endpoint requires both the account header
/// and the upstream `client_version` query parameter.
pub async fn fetch_codex_models_with_transport(
  transport : &OpenAIModelsHttpTransport,
  base_url : String,
  access_token : String,
  account_id : String,
  client_version : String,
) -> Array[CodexModelInfo] raise @posoco.ModelError {
  if account_id.length() == 0 {
    raise @posoco.ModelError::Transport(
      "Codex models request requires chatgpt-account-id metadata",
    )
  }
  let headers : Map[String, String] = Map::from_array([
    ("Authorization", "Bearer " + access_token),
    ("Accept", "application/json"),
    ("chatgpt-account-id", account_id),
  ])
  let payload = fetch_models_with_transport(
    transport,
    codex_models_url(base_url, client_version),
    headers,
  )
  parse_codex_models(payload)
}

///|
/// Fetch standard OpenAI model ids, retained as a source-compatible helper for
/// existing extension consumers.
pub async fn fetch_models(
  base_url : String,
  api_key : String,
) -> Array[String] raise @posoco.ModelError {
  let transport_impl = DefaultOpenAIModelsHttpTransport::DefaultOpenAIModelsHttpTransport()
  let transport : &OpenAIModelsHttpTransport = transport_impl
  let models = fetch_openai_models_with_transport(transport, base_url, api_key)
  models.map(fn(model) { model.id })
}

///|
pub async fn fetch_openai_models(
  base_url : String,
  api_key : String,
) -> Array[OpenAIModelInfo] raise @posoco.ModelError {
  let transport_impl = DefaultOpenAIModelsHttpTransport::DefaultOpenAIModelsHttpTransport()
  let transport : &OpenAIModelsHttpTransport = transport_impl
  fetch_openai_models_with_transport(transport, base_url, api_key)
}

///|
pub async fn fetch_codex_models(
  base_url : String,
  access_token : String,
  account_id : String,
  client_version? : String = openai_codex_models_client_version(),
) -> Array[CodexModelInfo] raise @posoco.ModelError {
  let transport_impl = DefaultOpenAIModelsHttpTransport::DefaultOpenAIModelsHttpTransport()
  let transport : &OpenAIModelsHttpTransport = transport_impl
  fetch_codex_models_with_transport(
    transport, base_url, access_token, account_id, client_version,
  )
}
