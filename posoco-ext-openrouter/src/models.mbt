///|
/// OpenRouter `GET /api/v1/models` endpoint.
///
/// The response is the OpenAI ListModels envelope with OpenRouter-specific
/// per-model metadata: `context_length`, and a `reasoning` object whose
/// `supported_efforts`/`default_effort`/`default_enabled` fields describe the
/// model's thinking surface. Those fields map directly onto the picker's
/// effort vocabulary, so discovery replaces the hand-declared
/// `thinking_efforts` settings once the first refresh lands. Model ids are
/// vendor-qualified slugs (`anthropic/claude-sonnet-4.5`) and are stored
/// verbatim as `model_id`; the slot id qualifies them further as
/// `openrouter/<slug>`.

///|
pub(all) struct OpenRouterModelInfo {
  id : String
  context_length : Int?
  reasoning_supported : Bool
  supported_efforts : Array[String]
  default_effort : String?
  default_enabled : Bool
  supports_images : Bool
} derive(Eq, Debug)

///|
pub fn parse_openrouter_models(
  payload : Json,
) -> Array[OpenRouterModelInfo] raise @posoco.ModelError {
  let root = match payload {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenRouter models response must be an object",
      )
  }
  let items = match root.get("data") {
    Some(Json::Array(values)) => values
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenRouter models response data must be an array",
      )
  }
  let result : Array[OpenRouterModelInfo] = []
  for item in items {
    let fields = match item {
      Json::Object(fields) => fields
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "OpenRouter models data item must be an object",
        )
    }
    let id = match fields.get("id") {
      Some(Json::String(value)) if value.length() > 0 => value
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "OpenRouter models item is missing a non-empty string id",
        )
    }
    let context_length = match fields.get("context_length") {
      Some(Json::Number(value, ..)) => Some(value.to_int())
      _ => None
    }
    let mut reasoning_supported = false
    let supported_efforts : Array[String] = []
    let mut default_effort : String? = None
    let mut default_enabled = false
    match fields.get("reasoning") {
      Some(Json::Object(reasoning)) => {
        reasoning_supported = true
        match reasoning.get("supported_efforts") {
          Some(Json::Array(values)) =>
            for value in values {
              match value {
                Json::String(effort) if effort.length() > 0 =>
                  supported_efforts.push(effort)
                _ => ()
              }
            }
          _ => ()
        }
        match reasoning.get("default_effort") {
          Some(Json::String(effort)) if effort.length() > 0 =>
            default_effort = Some(effort)
          _ => ()
        }
        match reasoning.get("default_enabled") {
          Some(Json::True) => default_enabled = true
          Some(Json::False) => default_enabled = false
          _ => ()
        }
      }
      _ =>
        match fields.get("supported_parameters") {
          Some(Json::Array(values)) =>
            for value in values {
              if value is Json::String("reasoning") {
                reasoning_supported = true
                default_enabled = true
              }
            }
          _ => ()
        }
    }
    let mut supports_images = false
    match fields.get("architecture") {
      Some(Json::Object(architecture)) =>
        match architecture.get("input_modalities") {
          Some(Json::Array(modalities)) =>
            for modality in modalities {
              if modality is Json::String("image") {
                supports_images = true
              }
            }
          _ => ()
        }
      _ => ()
    }
    result.push(OpenRouterModelInfo::{
      id,
      context_length,
      reasoning_supported,
      supported_efforts,
      default_effort,
      default_enabled,
      supports_images,
    })
  }
  result
}

///|
pub fn parse_cached_openrouter_models(
  records : Json?,
) -> Array[OpenRouterModelInfo]? {
  let items = match records {
    Some(Json::Array(items)) if items.length() > 0 => items
    _ => return None
  }
  let models : Array[OpenRouterModelInfo] = []
  for item in items {
    let fields = match item {
      Json::Object(fields) => fields
      _ => return None
    }
    let id = match fields.get("model_id") {
      Some(Json::String(value)) if value.length() > 0 => value
      _ => return None
    }
    let context_length = match fields.get("context_window") {
      Some(Json::Number(value, ..)) => Some(value.to_int())
      _ => None
    }
    let cached_efforts : Array[String] = []
    match fields.get("thinking_efforts") {
      Some(Json::Array(values)) =>
        for value in values {
          match value {
            Json::String(effort) if effort != "off" && effort != "on" =>
              cached_efforts.push(effort)
            _ => ()
          }
        }
      _ => ()
    }
    let mut reasoning_supported = false
    let mut default_effort : String? = None
    let mut default_enabled = false
    match fields.get("thinking_efforts") {
      Some(Json::Array(values)) if values.length() > 0 => {
        reasoning_supported = true
        match fields.get("default_effort") {
          Some(Json::String("on")) => default_enabled = true
          Some(Json::String("off")) => default_enabled = false
          Some(Json::String(effort)) => default_effort = Some(effort)
          _ => ()
        }
      }
      _ => ()
    }
    let supports_images = match fields.get("image_in") {
      Some(Json::True) => true
      _ => false
    }
    models.push(OpenRouterModelInfo::{
      id,
      context_length,
      reasoning_supported,
      supported_efforts: cached_efforts,
      default_effort,
      default_enabled,
      supports_images,
    })
  }
  Some(models)
}

///|
fn openrouter_config_for_info(
  api_key : String,
  base_url : String,
  info : OpenRouterModelInfo,
  http_referer : String?,
  title : String?,
) -> OpenRouterConfig {
  if info.supported_efforts.length() > 0 {
    let initial = match info.default_effort {
      Some(effort) if info.supported_efforts.contains(effort) => effort
      _ => info.supported_efforts[0]
    }
    OpenRouterConfig(
      api_key,
      model=info.id,
      base_url~,
      thinking=true,
      reasoning_effort=Some(initial),
      thinking_efforts=info.supported_efforts.copy(),
      context_window=info.context_length,
      http_referer~,
      title~,
      supports_images=info.supports_images,
    )
  } else if info.reasoning_supported {
    OpenRouterConfig(
      api_key,
      model=info.id,
      base_url~,
      thinking=info.default_enabled,
      context_window=info.context_length,
      http_referer~,
      title~,
      supports_images=info.supports_images,
    )
  } else {
    OpenRouterConfig(
      api_key,
      model=info.id,
      base_url~,
      context_window=info.context_length,
      http_referer~,
      title~,
      supports_images=info.supports_images,
    )
  }
}

///|
fn openrouter_preferred_models(
  models : Array[OpenRouterModelInfo],
  preferred_id : String,
) -> Array[OpenRouterModelInfo] {
  let result : Array[OpenRouterModelInfo] = []
  let mut preferred : OpenRouterModelInfo? = None
  for model in models {
    if model.id == preferred_id {
      preferred = Some(model)
    } else {
      result.push(model)
    }
  }
  match preferred {
    Some(model) => {
      let ordered : Array[OpenRouterModelInfo] = [model]
      ordered.append(result)
      ordered
    }
    None => models
  }
}

///|
pub fn openrouter_model_catalog(
  api_key : String,
  base_url : String,
  models : Array[OpenRouterModelInfo],
  preferred_id : String,
  api_key_factory : &@llm.ApiKeyFactory,
  http_referer? : String? = None,
  title? : String? = None,
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  if models.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_openrouter",
      detail="OpenRouter models endpoint returned an empty catalog",
    )
  }
  let prompt_cache_key_rejection_state : Ref[Bool] = Ref(false)
  let slots : Array[@llm.ModelSlot] = []
  for info in openrouter_preferred_models(models, preferred_id) {
    let config = openrouter_config_for_info(
      api_key, base_url, info, http_referer, title,
    )
    slots.push(
      openrouter_catalog_slot(
        config,
        api_key_factory,
        prompt_cache_key_rejection_state,
      ),
    )
  }
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="openrouter",
    slots~,
    capabilities=["chat", "streaming", "reasoning", "api_key"],
  )
}
