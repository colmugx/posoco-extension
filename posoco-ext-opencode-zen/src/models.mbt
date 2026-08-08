///|
/// OpenCode Zen `/models` endpoint.
///
/// Zen exposes the standard OpenAI `ListModels` envelope
/// (`{object:"list", data:[{id, object:"model", owned_by}]}`). The model ids
/// are bare (`claude-opus-5`, `gpt-5.1-codex`, ...) — the `opencode/` prefix
/// shown in Zen's docs is the *provider-qualified* form used in agent config,
/// not what the catalog endpoint returns. This extension stores the bare id
/// as `model_id` and qualifies the slot `id` as `opencode/<bare-id>` so the
/// picker shows the user-facing form.
///
/// Zen does not publish per-model capability fields, so — unlike DeepSeek —
/// every slot is treated as a plain chat model (no reasoning-effort selector).

///|
/// One model entry decoded from Zen's `/models` response.
pub(all) struct ZenModelInfo {
  id : String
  owned_by : String
} derive(Eq, Debug)

///|
/// Parse a Zen list response without performing I/O. Pure decoder shared by
/// the live fetch path and the white-box tests.
pub fn parse_zen_models(
  payload : Json,
) -> Array[ZenModelInfo] raise @posoco.ModelError {
  let root = match payload {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenCode Zen models response must be an object",
      )
  }
  match root.get("object") {
    Some(Json::String("list")) => ()
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "OpenCode Zen models response object must be list",
      )
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "OpenCode Zen models response object must be a string",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "OpenCode Zen models response is missing object",
      )
  }
  let items = match root.get("data") {
    Some(Json::Array(values)) => values
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenCode Zen models response data must be an array",
      )
  }
  let result : Array[ZenModelInfo] = []
  for item in items {
    let fields = match item {
      Json::Object(fields) => fields
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "OpenCode Zen models data item must be an object",
        )
    }
    let id = match fields.get("id") {
      Some(Json::String(value)) if value.length() > 0 => value
      Some(Json::String(_)) =>
        raise @posoco.ModelError::ResponseParse(
          "OpenCode Zen models item id must not be empty",
        )
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "OpenCode Zen models item is missing string id",
        )
    }
    match fields.get("object") {
      Some(Json::String("model")) => ()
      Some(Json::String(_)) =>
        raise @posoco.ModelError::ResponseParse(
          "OpenCode Zen models item object must be model",
        )
      Some(_) =>
        raise @posoco.ModelError::ResponseParse(
          "OpenCode Zen models item object must be a string",
        )
      None =>
        raise @posoco.ModelError::ResponseParse(
          "OpenCode Zen models item is missing object",
        )
    }
    let owned_by = match fields.get("owned_by") {
      Some(Json::String(value)) if value.length() > 0 => value
      Some(Json::String(_)) =>
        raise @posoco.ModelError::ResponseParse(
          "OpenCode Zen models item owned_by must not be empty",
        )
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "OpenCode Zen models item is missing string owned_by",
        )
    }
    result.push(ZenModelInfo::{ id, owned_by })
  }
  result
}

///|
fn zen_models_url(base_url : String, endpoint_prefix : String) -> String {
  let clean = match base_url.strip_suffix("/") {
    Some(value) => value.to_owned()
    None => base_url
  }
  clean + endpoint_prefix + "/models"
}
