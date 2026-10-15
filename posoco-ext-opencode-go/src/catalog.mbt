///|
/// Catalog construction for OpenCode Go: the subscription plane over the
/// shared OpenCode multi-protocol wire machinery from
/// `posoco-ext-opencode-zen`. One gateway plane, many models, each model one
/// slot over an `OpenCodeZenModelPort` carrying this plane's base URL,
/// identity, and spend source.

///|
/// The provider id this extension claims. Distinct from the pay-as-you-go
/// `opencode` id — and deliberately isolated from it: a Zen key querying the
/// Go usage endpoint answers `403 EntitlementError`, so the two planes never
/// share a credential seam.
let go_provider_id : String = "opencode-go"

///|
/// The conventional Go base URL. Exposed so the factory default and tests
/// reference one source of truth. The legacy `https://opencode.ai/zen/go/v1`
/// spelling keeps working via the `base_url` setting (same gateway).
let go_default_base_url : String = "https://opencode.ai/inference/go/v1"

///|
/// The default model: a cheap, high-allowance coding model from the
/// vendor's own Go table ($60/month on Go, $0.15/$0.50 pricing) — a safe
/// first slot before the live catalog arrives.
let go_default_model : String = "glm-5.3-flash"

///|
/// The Go-plane wire table: where the Go gateway disagrees with the shared
/// family rules or with the Zen plane. The vendor's Go endpoints table is
/// the authority — qwen3.8-max/flash and MiniMax M3/M2.7 are served on the
/// Anthropic @zen.Messages plane here (they sit on chat completions on Zen), and
/// everything else follows the family rules (luna/grok/muse → @zen.Responses,
/// claude/haiku → @zen.Messages, glm/kimi/longcat/deepseek/mimo/hy/space-bunny
/// → the Chat Completions default).
let go_wire_overrides : Map[String, @zen.WireKind] = Map::from_array([
  ("qwen3.8-max", @zen.Messages),
  ("qwen3.8-flash", @zen.Messages),
  ("minimax-m3", @zen.Messages),
  ("minimax-m2.7", @zen.Messages),
])

///|
/// Resolve one model's wire for the Go gateway. Precedence: settings
/// override, Go-plane table, models.dev npm signal, family fallback,
/// gateway default (Chat Completions).
pub fn resolve_go_wire(
  model_id : String,
  npm~ : String? = None,
  overrides~ : Map[String, String] = Map::from_array([]),
) -> @zen.WireKind {
  match overrides.get(model_id) {
    Some(id) =>
      match @zen.wire_kind_of_id(id) {
        Some(kind) => return kind
        None => ()
      }
    None => ()
  }
  match go_wire_overrides.get(model_id) {
    Some(kind) => return kind
    None => ()
  }
  match npm {
    Some(value) =>
      match @zen.wire_from_models_dev_npm(Some(value)) {
        Some(kind) => return kind
        None => ()
      }
    None => ()
  }
  match @zen.wire_from_family(model_id) {
    Some(kind) => kind
    None => @zen.ChatCompletions
  }
}

///|
/// Reconstruct a reasoning surface from host-cached slot records (the static
/// build path) — the same projection the zen plane caches.
fn go_cached_surface(info : @zen.ZenModelInfo) -> @zen.ZenReasoningSurface? {
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
/// Resolve one model's reasoning surface: fresh models.dev metadata wins,
/// the host cache is the offline fallback.
fn go_model_surface(
  info : @zen.ZenModelInfo,
  metas : Map[String, @zen.ZenModelMeta],
) -> @zen.ZenReasoningSurface? {
  match metas.get(info.id) {
    Some(meta) => Some(meta.surface)
    None => go_cached_surface(info)
  }
}

///|
/// Build one catalog slot for a Go model: the shared wire port wrapped in
/// the rate-limit recovery decorator (fills `reset_at_ms` from the
/// `/usage` probe so the host's guard schedules automatic recovery), then
/// the anchored-compact wrapper, carrying this plane's identity and spend
/// source.
fn go_catalog_slot(
  config : @zen.OpenCodeZenConfig,
  surface : @zen.ZenReasoningSurface?,
  api_key : &@llm.ApiKeyFactory,
) -> @llm.ModelSlot {
  let wire_port : &@posoco.ModelPort = @zen.opencode_anchored_compact_port(
    config,
  )
  let port : &@posoco.ModelPort = GoRateLimitModelPort(
    inner=wire_port,
    base_url=config.base_url,
    api_key=config.api_key,
  )
  let slot_id = go_provider_id + "/" + config.model
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
          abort("OpenCode Go catalog effort rebuild failed: " + err.to_string())
      }
      go_catalog_slot(rebuilt_config, surface, api_key)
    })
  } else {
    None
  }
  let capabilities : Array[String] = if config.supports_images {
    ["chat", "streaming", "api_key", "image_in"]
  } else {
    ["chat", "streaming", "api_key"]
  }
  @llm.ModelSlot::ModelSlot(
    id=slot_id,
    label="Go / " + config.model,
    provider_id=go_provider_id,
    model_id=config.model,
    port~,
    api_key=Some(api_key),
    thinking_efforts=slot_efforts,
    capabilities~,
    default_effort~,
    display_group=Some("go"),
    rebuild_on_api_key=Some(fn(credential) {
      let rebuilt_config : @zen.OpenCodeZenConfig = {
        ..config,
        api_key: credential.secret,
      }
      go_catalog_slot(rebuilt_config, surface, api_key)
    }),
    rebuild_on_effort~,
  )
}

///|
/// Keep the configured model first after a live refresh while preserving the
/// gateway's server order for the rest.
fn go_preferred_models(
  models : Array[@zen.ZenModelInfo],
  preferred_id : String,
) -> Array[@zen.ZenModelInfo] {
  let result : Array[@zen.ZenModelInfo] = []
  let mut preferred : @zen.ZenModelInfo? = None
  for model in models {
    if model.id == preferred_id {
      preferred = Some(model)
    } else {
      result.push(model)
    }
  }
  match preferred {
    Some(model) => {
      let ordered : Array[@zen.ZenModelInfo] = [model]
      ordered.append(result)
      ordered
    }
    None => models
  }
}

///|
/// Build a Go config for one discovered model from the plane's base config.
/// The wire derives from the settings override, the Go-plane table, the
/// models.dev SDK signal, and the family fallback; window/image/rate facts
/// come from the fresh metadata with the host cache as the offline fallback.
fn go_config_for_model(
  base : @zen.OpenCodeZenConfig,
  info : @zen.ZenModelInfo,
  surface : @zen.ZenReasoningSurface?,
  meta : @zen.ZenModelMeta?,
  overrides~ : Map[String, String] = Map::from_array([]),
) -> @zen.OpenCodeZenConfig {
  let wire = resolve_go_wire(
    info.id,
    npm=match meta {
      Some(meta) => meta.provider_npm
      None => None
    },
    overrides~,
  )
  let context_window : Int32? = match meta {
    Some(meta) => meta.context_window
    None => info.context_window
  }
  let supports_images = match meta {
    Some(meta) => meta.supports_images
    None => info.supports_images
  }
  let rates : @zen.ZenCostRates? = match meta {
    Some(meta) => meta.rates
    None => None
  }
  match surface {
    Some(surface) if surface.reasoning && !surface.levels.is_empty() =>
      @zen.OpenCodeZenConfig(
        base.api_key,
        base_url=base.base_url,
        model=info.id,
        endpoint_prefix=base.endpoint_prefix,
        thinking=true,
        reasoning_effort=Some(@zen.zen_preset_default_level(surface.levels)),
        thinking_efforts=surface.levels.copy(),
        context_window~,
        supports_images~,
        wire~,
        max_output_tokens=base.max_output_tokens,
        rates~,
        client_id=base.client_id,
        spend_source=base.spend_source,
      )
    _ =>
      @zen.OpenCodeZenConfig(
        base.api_key,
        base_url=base.base_url,
        model=info.id,
        endpoint_prefix=base.endpoint_prefix,
        context_window~,
        supports_images~,
        wire~,
        max_output_tokens=base.max_output_tokens,
        rates~,
        client_id=base.client_id,
        spend_source=base.spend_source,
      )
  }
}

///|
/// Build a single-slot catalog for the static `build` path (no network):
/// the configured model over its derived wire, safe off/on picker, and the
/// host cache (when present) expanded offline into the full list.
pub fn go_static_catalog(
  config : @zen.OpenCodeZenConfig,
  api_key : &@llm.ApiKeyFactory,
  overrides~ : Map[String, String] = Map::from_array([]),
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id=go_provider_id,
    slots=[
      go_catalog_slot(
        go_config_for_model(
          config,
          @zen.ZenModelInfo::{
            id: config.model,
            owned_by: "",
            cached_efforts: [],
            context_window: config.context_window,
            supports_images: config.supports_images,
          },
          None,
          None,
          overrides~,
        ),
        None,
        api_key,
      ),
    ],
    capabilities=["chat", "streaming", "api_key"],
  )
}

///|
/// Build a multi-slot catalog from the gateway's live `/models` response.
/// `metas` carries the models.dev-derived metadata (the mirror has no Go
/// section, so Go-only ids degrade to the safe fallbacks). Models resolving
/// to an unserved wire are excluded rather than offered on a wire that
/// would answer `400 ModelProtocolUnsupported`. Raises on an empty list so
/// a transient glitch surfaces as a typed composition failure.
pub fn go_model_catalog(
  base_config : @zen.OpenCodeZenConfig,
  models : Array[@zen.ZenModelInfo],
  preferred_id : String,
  metas : Map[String, @zen.ZenModelMeta],
  api_key : &@llm.ApiKeyFactory,
  overrides~ : Map[String, String] = Map::from_array([]),
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  if models.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_opencode_go",
      detail="OpenCode Go models endpoint returned an empty catalog",
    )
  }
  let servable : Array[@zen.ZenModelInfo] = []
  for info in go_preferred_models(models, preferred_id) {
    let npm = match metas.get(info.id) {
      Some(meta) => meta.provider_npm
      None => None
    }
    if @zen.wire_servable(resolve_go_wire(info.id, npm~, overrides~)) {
      servable.push(info)
    }
  }
  if servable.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_opencode_go",
      detail="OpenCode Go models endpoint returned no servable models",
    )
  }
  let slots : Array[@llm.ModelSlot] = []
  for info in servable {
    let surface = go_model_surface(info, metas)
    let config = go_config_for_model(
      base_config,
      info,
      surface,
      metas.get(info.id),
      overrides~,
    )
    slots.push(go_catalog_slot(config, surface, api_key))
  }
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id=go_provider_id,
    slots~,
    capabilities=["chat", "streaming", "api_key"],
  )
}
