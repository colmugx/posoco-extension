///
/// Z.ai / BigModel authenticated `/models` endpoint.
///
/// Both platforms follow the OpenAI list envelope (`{"object": "list",
/// "data": [...]}`), but their model records carry platform-specific extra
/// fields. Parsing is therefore tolerant: `data` with non-empty string `id`s
/// is the contract; `object` is checked only when present; every other field
/// is ignored. Thinking profiles are a deterministic provider policy
/// (`zai_model_info` by GLM generation), not a field read from the response.

///|
fn zai_models_url(base_url : String, endpoint_prefix : String) -> String {
  let clean = match base_url.strip_suffix("/") {
    Some(value) => value.to_owned()
    None => base_url
  }
  clean + endpoint_prefix + "/models"
}

///|
/// Parse a z.ai /models response without performing I/O. Duplicate ids keep
/// their first occurrence; an empty or shapeless list is a typed parse error
/// (an empty catalog is never silently announced).
pub fn parse_zai_models(
  payload : Json,
) -> Array[String] raise @posoco.ModelError {
  let root = match payload {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "zai models response must be an object",
      )
  }
  match root.get("object") {
    Some(Json::String("list")) => ()
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "zai models response object must be list",
      )
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "zai models response object must be a string",
      )
    None => ()
  }
  let items = match root.get("data") {
    Some(Json::Array(values)) => values
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "zai models response data must be an array",
      )
  }
  let ids : Array[String] = []
  for item in items {
    let fields = match item {
      Json::Object(fields) => fields
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "zai models data item must be an object",
        )
    }
    let id = match fields.get("id") {
      Some(Json::String(value)) if value.length() > 0 => value
      Some(Json::String(_)) =>
        raise @posoco.ModelError::ResponseParse(
          "zai models item id must not be empty",
        )
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "zai models item is missing string id",
        )
    }
    if !ids.contains(id) {
      ids.push(id)
    }
  }
  if ids.is_empty() {
    raise @posoco.ModelError::ResponseParse(
      "zai models response contains no models",
    )
  }
  ids
}

///|
/// Tolerantly decode host-cached model records (cetas `catalog_model_records`
/// projection) for offline catalog expansion. Only `model_id` is consumed:
/// reasoning profiles are a deterministic provider policy, so a catalog
/// rebuilt from cached ids is identical to the live-refresh catalog for those
/// ids. Malformed shapes degrade to `None` (the preset catalog stands) and
/// never fail composition — the cache is derived, re-derivable data.
pub fn parse_cached_zai_models(records : Json?) -> Array[String]? {
  let items = match records {
    Some(Json::Array(items)) if items.length() > 0 => items
    _ => return None
  }
  let ids : Array[String] = []
  for item in items {
    let id = match item {
      Json::Object(fields) =>
        match fields.get("model_id") {
          Some(Json::String(value)) if value.length() > 0 => value
          _ => return None
        }
      _ => return None
    }
    if !ids.contains(id) {
      ids.push(id)
    }
  }
  Some(ids)
}

///|
/// Fetch and decode the live Z.ai / BigModel model list.
pub async fn fetch_zai_models(
  base_url : String,
  api_key : String,
  endpoint_prefix? : String = "",
) -> Array[String] raise @posoco.ModelError {
  let headers : @http.Headers = {
    "Authorization": "Bearer " + api_key,
    "Accept": "application/json",
    "Accept-Language": "en-US,en",
  }
  let (response, body_data) = @async.with_timeout(30000, () => {
    @http.get(zai_models_url(base_url, endpoint_prefix), headers~)
  }) catch {
    @async.TimeoutError =>
      raise @posoco.ModelError::Transport(
        "zai list models request timed out (timeout_ms=30000)",
      )
    err =>
      raise @posoco.ModelError::Transport(
        "zai list models request failed: " + err.to_string(),
      )
  }
  if response.code < 200 || response.code >= 300 {
    raise @posoco.ModelError::Transport(
      "zai list models HTTP status: " +
      response.code.to_string() +
      ", body_bytes=" +
      body_data.binary().length().to_string(),
    )
  }
  let body_text = body_data.text() catch {
    err =>
      raise @posoco.ModelError::Transport(
        "zai list models body read failed: " + err.to_string(),
      )
  }
  let payload = @json.parse(body_text) catch {
    err =>
      raise @posoco.ModelError::ResponseParse(
        "zai list models JSON parse failed: " + err.to_string(),
      )
  }
  parse_zai_models(payload)
}
