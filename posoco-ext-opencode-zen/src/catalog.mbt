///|
/// Catalog construction for OpenCode Zen: one gateway, many models, each
/// model one slot over an OpenCodeZenModelPort.

///|
/// The provider id this extension claims. Centralised so the factory, catalog,
/// and credential store agree even if Zen ever ships under a different id.
let zen_provider_id : String = "opencode"

///|
/// The conventional Zen base URL. Exposed so the factory default and tests
/// reference one source of truth.
let zen_default_base_url : String = "https://opencode.ai/zen/v1"

///|
/// The models.dev mirror OpenCode publishes its model metadata at — the
/// canonical source of the per-model reasoning surface. A fixed constant with
/// no settings override: a refresh either reads the same catalog OpenCode
/// itself reads, or degrades to the off/on fallback picker.
let zen_models_dev_url : String = "https://models.opencode.ai/api.json"

///|
/// Reconstruct a reasoning surface from host-cached slot records (the static
/// build path). The cache stores the previous refresh's full picker, so
/// "off" marks a disableable model, "on" is toggle residue, and every other
/// entry is a level. Whether the model reasons at all is not recoverable
/// offline: an empty cached picker degrades to `None`, which maps to the
/// off/on fallback with thinking off.
fn zen_cached_surface(info : ZenModelInfo) -> ZenReasoningSurface? {
  if info.cached_efforts.is_empty() {
    return None
  }
  let levels : Array[String] = []
  let mut can_disable = false
  for effort in info.cached_efforts {
    if effort == "off" {
      can_disable = true
    } else if effort != "on" {
      levels.push(effort)
    }
  }
  Some({ reasoning: true, levels, can_disable, })
}

///|
/// Resolve one model's reasoning surface: the freshly decoded models.dev map
/// wins; the host cache (the previous refresh's picker) is the offline
/// fallback for models the fresh map does not cover.
fn zen_model_surface(
  info : ZenModelInfo,
  surfaces : Map[String, ZenReasoningSurface],
) -> ZenReasoningSurface? {
  match surfaces.get(info.id) {
    Some(surface) => Some(surface)
    None => zen_cached_surface(info)
  }
}

///|
/// Build one catalog slot for a Zen model. `surface` drives the picker:
/// a level-bearing reasoning surface shows `off` (when thinking can be
/// disabled) followed by its declared levels; a reasoning model without
/// levels, and a model whose surface is unknown, fall back to the safe
/// `off` / `on` toggle; a plain chat model shows no selector at all.
fn zen_catalog_slot(
  config : OpenCodeZenConfig,
  surface : ZenReasoningSurface?,
  api_key : &@llm.ApiKeyFactory,
) -> @llm.ModelSlot {
  let port : &@posoco.ModelPort = zen_retry_port(OpenCodeZenModelPort(config))
  let slot_id = zen_provider_id + "/" + config.model
  let slot_efforts : Array[String] = match surface {
    None => ["off", "on"]
    Some(surface) =>
      if !surface.reasoning {
        []
      } else if surface.levels.is_empty() {
        ["off", "on"]
      } else {
        let picker : Array[String] = []
        if surface.can_disable {
          picker.push("off")
        }
        picker.append(surface.levels.copy())
        picker
      }
  }
  let label = if !config.thinking {
    "off"
  } else {
    match config.reasoning_effort {
      Some(effort) => effort
      None => "on"
    }
  }
  let selectable = !slot_efforts.is_empty()
  let default_effort : String? = if selectable { Some(label) } else { None }
  let rebuild_on_effort : ((String) -> @llm.ModelSlot)? = if selectable {
    Some(fn(effort) {
      let rebuilt_config = config.with_reasoning_effort(effort) catch {
        err =>
          abort(
            "OpenCode Zen catalog effort rebuild failed: " + err.to_string(),
          )
      }
      zen_catalog_slot(rebuilt_config, surface, api_key)
    })
  } else {
    None
  }
  @llm.ModelSlot::ModelSlot(
    id=slot_id,
    label="Zen / " + config.model,
    provider_id=zen_provider_id,
    model_id=config.model,
    port~,
    api_key=Some(api_key),
    thinking_efforts=slot_efforts,
    capabilities=["chat", "streaming", "api_key"],
    default_effort~,
    display_group=Some("zen"),
    rebuild_on_api_key=Some(fn(credential) {
      let rebuilt_config = OpenCodeZenConfig(
        credential.secret,
        base_url=config.base_url,
        model=config.model,
        endpoint_prefix=config.endpoint_prefix,
        thinking=config.thinking,
        reasoning_effort=config.reasoning_effort,
        thinking_efforts=config.thinking_efforts,
      )
      zen_catalog_slot(rebuilt_config, surface, api_key)
    }),
    rebuild_on_effort~,
  )
}

///|
/// Keep the configured model first after a live refresh while preserving the
/// gateway's server order for all remaining models, so a user who pinned a
/// model keeps it at the top of the refreshed list.
fn zen_preferred_models(
  models : Array[ZenModelInfo],
  preferred_id : String,
) -> Array[ZenModelInfo] {
  let result : Array[ZenModelInfo] = []
  let mut preferred : ZenModelInfo? = None
  for model in models {
    if model.id == preferred_id {
      preferred = Some(model)
    } else {
      result.push(model)
    }
  }
  match preferred {
    Some(model) => {
      let ordered : Array[ZenModelInfo] = [model]
      ordered.append(result)
      ordered
    }
    None => models
  }
}

///|
/// Build a Zen config for one discovered model from a base config (the
/// user's resolved credential/endpoint). Each model shares the endpoint and
/// key; the reasoning surface decides the wire state: a level-bearing model
/// starts on its default level with the levels attached, every other shape
/// stays thinking-off (which omits the reasoning surface on the wire, so the
/// gateway applies the model's own default).
fn zen_config_for_model(
  base : OpenCodeZenConfig,
  model_id : String,
  surface : ZenReasoningSurface?,
) -> OpenCodeZenConfig {
  match surface {
    Some(surface) if surface.reasoning && !surface.levels.is_empty() =>
      OpenCodeZenConfig(
        base.api_key,
        base_url=base.base_url,
        model=model_id,
        endpoint_prefix=base.endpoint_prefix,
        thinking=true,
        reasoning_effort=Some(zen_preset_default_level(surface.levels)),
        thinking_efforts=surface.levels.copy(),
      )
    _ =>
      OpenCodeZenConfig(
        base.api_key,
        base_url=base.base_url,
        model=model_id,
        endpoint_prefix=base.endpoint_prefix,
      )
  }
}

///|
/// Build a single-slot catalog for the static `build` path (no network). Used
/// by `ProviderFactory::build` so agent composition never blocks on the Zen
/// discovery endpoint; the full list arrives later via `refresh`. No surface
/// is known offline here, so the slot presents the safe off/on toggle and the
/// full catalog is reconstructed from host-cached records when available.
pub fn zen_static_catalog(
  config : OpenCodeZenConfig,
  api_key : &@llm.ApiKeyFactory,
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id=zen_provider_id,
    slots=[
      zen_catalog_slot(
        zen_config_for_model(config, config.model, None),
        None,
        api_key,
      ),
    ],
    capabilities=["chat", "streaming", "api_key"],
  )
}

///|
/// Build a multi-slot catalog from the gateway's live `/models` response.
/// `surfaces` carries the models.dev-derived reasoning surfaces; a model the
/// map does not cover falls back to its host-cached picker, and finally to
/// the off/on toggle. Raises on an empty list so a transient gateway glitch
/// surfaces as a typed composition failure rather than a silently empty
/// picker.
pub fn zen_model_catalog(
  base_config : OpenCodeZenConfig,
  models : Array[ZenModelInfo],
  preferred_id : String,
  surfaces : Map[String, ZenReasoningSurface],
  api_key : &@llm.ApiKeyFactory,
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  if models.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_opencode_zen",
      detail="OpenCode Zen models endpoint returned an empty catalog",
    )
  }
  let slots : Array[@llm.ModelSlot] = []
  for info in zen_preferred_models(models, preferred_id) {
    let surface = zen_model_surface(info, surfaces)
    let config = zen_config_for_model(base_config, info.id, surface)
    slots.push(zen_catalog_slot(config, surface, api_key))
  }
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id=zen_provider_id,
    slots~,
    capabilities=["chat", "streaming", "api_key"],
  )
}
