///
/// DeepSeek's authenticated /models endpoint.
///
/// DeepSeek follows the OpenAI list envelope, but its model records are
/// intentionally small: id, object, and owned_by are the complete documented
/// schema. Reasoning levels are therefore a provider policy (the current
/// v4/reasoner families accept high and max), not a fabricated field read from
/// an unrelated response.

///|
pub(all) struct DeepSeekModelInfo {
  id : String
  owned_by : String
  thinking_efforts : Array[String]
  default_effort : String?
}

///|
fn deepseek_model_efforts(model_id : String) -> Array[String] {
  // The public DeepSeek /models schema does not carry capability fields.
  // Keep this mapping provider-owned and conservative: only model families
  // documented as reasoning models expose a selectable effort.
  if model_id.contains("reasoner") || model_id.has_prefix("deepseek-v4-") {
    ["high", "max"]
  } else {
    []
  }
}

///|
/// Parse a DeepSeek list response without performing I/O.
pub fn parse_deepseek_models(
  payload : Json,
) -> Array[DeepSeekModelInfo] raise @posoco.ModelError {
  let root = match payload {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek models response must be an object",
      )
  }
  match root.get("object") {
    Some(Json::String("list")) => ()
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek models response object must be list",
      )
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek models response object must be a string",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek models response is missing object",
      )
  }
  let items = match root.get("data") {
    Some(Json::Array(values)) => values
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek models response data must be an array",
      )
  }
  let result : Array[DeepSeekModelInfo] = []
  for item in items {
    let fields = match item {
      Json::Object(fields) => fields
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "DeepSeek models data item must be an object",
        )
    }
    let id = match fields.get("id") {
      Some(Json::String(value)) if value.length() > 0 => value
      Some(Json::String(_)) =>
        raise @posoco.ModelError::ResponseParse(
          "DeepSeek models item id must not be empty",
        )
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "DeepSeek models item is missing string id",
        )
    }
    match fields.get("object") {
      Some(Json::String("model")) => ()
      Some(Json::String(_)) =>
        raise @posoco.ModelError::ResponseParse(
          "DeepSeek models item object must be model",
        )
      Some(_) =>
        raise @posoco.ModelError::ResponseParse(
          "DeepSeek models item object must be a string",
        )
      None =>
        raise @posoco.ModelError::ResponseParse(
          "DeepSeek models item is missing object",
        )
    }
    let owned_by = match fields.get("owned_by") {
      Some(Json::String(value)) if value.length() > 0 => value
      Some(Json::String(_)) =>
        raise @posoco.ModelError::ResponseParse(
          "DeepSeek models item owned_by must not be empty",
        )
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "DeepSeek models item is missing string owned_by",
        )
    }
    let efforts = deepseek_model_efforts(id)
    let default_effort = if efforts.is_empty() {
      None
    } else {
      Some(efforts[0])
    }
    result.push(DeepSeekModelInfo::{
      id,
      owned_by,
      thinking_efforts: efforts,
      default_effort,
    })
  }
  result
}

///|
fn deepseek_models_url(base_url : String, endpoint_prefix : String) -> String {
  let clean = match base_url.strip_suffix("/") {
    Some(value) => value.to_owned()
    None => base_url
  }
  clean + endpoint_prefix + "/models"
}

///|
/// Tolerantly decode host-cached model records for offline catalog expansion.
/// Only the model id is consumed: reasoning profiles are a deterministic
/// provider policy (`deepseek_model_efforts`), so a catalog rebuilt from
/// cached ids is identical to the live-refresh catalog for those ids.
/// Malformed shapes degrade to `None` (the static single-model build) and
/// never fail composition — the cache is derived, re-derivable data.
fn parse_cached_deepseek_models(records : Json?) -> Array[DeepSeekModelInfo]? {
  let items = match records {
    Some(Json::Array(items)) if items.length() > 0 => items
    _ => return None
  }
  let models : Array[DeepSeekModelInfo] = []
  for item in items {
    let id = match item {
      Json::Object(fields) =>
        match fields.get("model_id") {
          Some(Json::String(value)) if value.length() > 0 => value
          _ => return None
        }
      _ => return None
    }
    let efforts = deepseek_model_efforts(id)
    let default_effort = if efforts.is_empty() {
      None
    } else {
      Some(efforts[0])
    }
    models.push(DeepSeekModelInfo::{
      id,
      owned_by: "deepseek",
      thinking_efforts: efforts,
      default_effort,
    })
  }
  Some(models)
}

///|
/// Fetch and decode the live DeepSeek model catalog.
pub async fn fetch_deepseek_models(
  base_url : String,
  api_key : String,
  endpoint_prefix? : String = "",
) -> Array[DeepSeekModelInfo] raise @posoco.ModelError {
  let headers : @http.Headers = {
    "Authorization": "Bearer " + api_key,
    "Accept": "application/json",
  }
  let (response, body_data) = @async.with_timeout(30000, () => {
    @http.get(deepseek_models_url(base_url, endpoint_prefix), headers~)
  }) catch {
    @async.TimeoutError =>
      raise @posoco.ModelError::Transport(
        "DeepSeek list models request timed out (timeout_ms=30000)",
      )
    err =>
      raise @posoco.ModelError::Transport(
        "DeepSeek list models request failed: " + err.to_string(),
      )
  }
  if response.code < 200 || response.code >= 300 {
    raise @posoco.ModelError::Transport(
      "DeepSeek list models HTTP status: " +
      response.code.to_string() +
      ", body_bytes=" +
      body_data.binary().length().to_string(),
    )
  }
  let body_text = body_data.text() catch {
    err =>
      raise @posoco.ModelError::Transport(
        "DeepSeek list models body read failed: " + err.to_string(),
      )
  }
  let payload = @json.parse(body_text) catch {
    err =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek list models JSON parse failed: " + err.to_string(),
      )
  }
  parse_deepseek_models(payload)
}
