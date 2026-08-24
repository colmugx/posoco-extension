///|
/// Catalog construction for OpenCode Zen.
///
/// Zen is a hosted gateway: one endpoint, many models behind it, all speaking
/// the OpenAI Chat Completions protocol. Each model becomes one catalog slot
/// whose `port` is a fresh `OpenAICompatibleModelPort` built over a config
/// carrying that model's id — so the wire layer (request encoding, SSE,
/// response decoding, error classification) is fully reused from
/// `posoco-ext-openai-compatible` and never duplicated here.

///|
/// The provider id this extension claims. Centralised so the factory, catalog,
/// and credential store agree even if Zen ever ships under a different id.
let zen_provider_id : String = "opencode"

///|
/// The conventional Zen base URL. Exposed so the factory default and tests
/// reference one source of truth.
let zen_default_base_url : String = "https://opencode.ai/zen/v1"

///|
/// Build one catalog slot for a Zen model. The port is an
/// `OpenAICompatibleModelPort` constructed with the Zen provider id, so chat
/// requests carry `Authorization: Bearer <key>` and post to
/// `base_url + endpoint_prefix + /chat/completions`. Zen-specific routing
/// metadata is supplied through the optional request-header hook.
///
/// The picker's effort surface comes from the curated preset table in
/// efforts.mbt: "off" only when the model allows disabling thinking, "on" for
/// toggle-only models, otherwise exactly the declared levels. `api_key` is the
/// factory reference stored on the slot so credential-driven rebuilds stay
/// inside this extension.
fn zen_catalog_slot(
  config : @openai_compatible.OpenAICompatibleConfig,
  api_key : &@llm.ApiKeyFactory,
) -> @llm.ModelSlot {
  let port : &@posoco.ModelPort = zen_retry_port(
    @openai_compatible.OpenAICompatibleModelPort(
      zen_provider_id,
      config,
      request_headers=zen_request_headers,
    ),
  )
  let slot_id = zen_provider_id + "/" + config.model
  let (slot_efforts, default_effort, rebuild_on_effort) : (
    Array[String],
    String?,
    ((String) -> @llm.ModelSlot)?,
  ) = match zen_effort_preset(config.model) {
    None => ([], None, None)
    Some(preset) => {
      let picker : Array[String] = []
      if preset.can_disable {
        picker.push("off")
      }
      if preset.levels.is_empty() {
        picker.push("on")
      } else {
        picker.append(preset.levels.copy())
      }
      let label = if !config.thinking {
        "off"
      } else {
        match config.reasoning_effort {
          Some(effort) => effort
          None => "on"
        }
      }
      let rebuild : ((String) -> @llm.ModelSlot)? = Some(fn(effort) {
        let rebuilt_config = config.with_reasoning_effort(effort) catch {
          err =>
            abort(
              "OpenCode Zen catalog effort rebuild failed: " + err.to_string(),
            )
        }
        zen_catalog_slot(rebuilt_config, api_key)
      })
      (picker, Some(label), rebuild)
    }
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
      let rebuilt_config = @openai_compatible.OpenAICompatibleConfig(
        credential.secret,
        base_url=config.base_url,
        model=config.model,
        endpoint_prefix=config.endpoint_prefix,
        thinking=config.thinking,
        reasoning_effort=config.reasoning_effort,
        thinking_efforts=config.thinking_efforts,
      )
      zen_catalog_slot(rebuilt_config, api_key)
    }),
    rebuild_on_effort~,
  )
}

///|
/// Keep the configured model first after a live refresh while preserving the
/// gateway's server order for all remaining models. Mirrors the DeepSeek
/// policy so a user who pinned a model keeps it at the top of the refreshed
/// list.
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
/// Build a Zen config for one discovered model from a base config (the user's
/// resolved credential/endpoint). Each model shares the endpoint and key; the
/// reasoning surface comes from the curated preset table: level-bearing models
/// start on their default level, toggle-only models start off, and unknown
/// models stay plain chat (both omit the reasoning surface on the wire, so the
/// gateway applies the model's own default).
fn zen_config_for_model(
  base : @openai_compatible.OpenAICompatibleConfig,
  model_id : String,
) -> @openai_compatible.OpenAICompatibleConfig {
  match zen_effort_preset(model_id) {
    Some(preset) =>
      if preset.levels.is_empty() {
        @openai_compatible.OpenAICompatibleConfig(
          base.api_key,
          base_url=base.base_url,
          model=model_id,
          endpoint_prefix=base.endpoint_prefix,
          thinking=false,
        )
      } else {
        @openai_compatible.OpenAICompatibleConfig(
          base.api_key,
          base_url=base.base_url,
          model=model_id,
          endpoint_prefix=base.endpoint_prefix,
          thinking=true,
          reasoning_effort=Some(zen_preset_default_level(preset.levels)),
          thinking_efforts=preset.levels.copy(),
        )
      }
    None =>
      @openai_compatible.OpenAICompatibleConfig(
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
/// discovery endpoint; the full list arrives later via `refresh`. The preset
/// table applies here too, so the configured model gets its reasoning surface
/// before the first refresh lands.
pub fn zen_static_catalog(
  config : @openai_compatible.OpenAICompatibleConfig,
  api_key : &@llm.ApiKeyFactory,
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id=zen_provider_id,
    slots=[
      zen_catalog_slot(zen_config_for_model(config, config.model), api_key),
    ],
    capabilities=["chat", "streaming", "api_key"],
  )
}

///|
/// Build a multi-slot catalog from the gateway's live `/models` response.
/// Raises on an empty list so a transient gateway glitch surfaces as a typed
/// composition failure rather than a silently empty picker.
pub fn zen_model_catalog(
  base_config : @openai_compatible.OpenAICompatibleConfig,
  models : Array[ZenModelInfo],
  preferred_id : String,
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
    let config = zen_config_for_model(base_config, info.id)
    slots.push(zen_catalog_slot(config, api_key))
  }
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id=zen_provider_id,
    slots~,
    capabilities=["chat", "streaming", "api_key"],
  )
}
