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
/// Whether the DeepSeek serving contract applies to this slot. The
/// request-local user guidance and the stream inspector are only
/// enabled for selected DeepSeek Chat Completions model slots.
fn go_deepseek_applies(config : @zen.OpenCodeZenConfig) -> Bool {
  config.wire == @zen.ChatCompletions &&
  @compatible.resolve(config.model).id == "deepseek"
}

///|
/// Relay the kit's stream bounds onto the shared wire's inspector seam.
fn go_deepseek_inspector(
  policy : @ds.DeepSeekPolicy,
  ctx : @devkit.ExtContext,
) -> (@posoco.StreamAccumulator, Bool) -> @zen.StreamVerdict {
  fn(acc, done) {
    match policy.observe(acc, done~) {
      None => @zen.StreamVerdict::Continue
      Some(breach) => {
        if breach == @ds.ReasoningBreach::RepetitionDetected {
          ctx.warn(
            source="posoco-ext-opencode-go",
            code="deepseek.reasoning_repetition_detected",
            message="Repeated reasoning suffix detected; aborting stream",
          )
        }
        @zen.StreamVerdict::Abort(
          category=breach.category(),
          message=breach.message(),
        )
      }
    }
  }
}

///|
/// The shared wire port behind the rate-limit recovery decorator, which
/// fills `reset_at_ms` from the `/usage` probe so the host's guard schedules
/// automatic recovery.
fn go_rate_limited_port(
  config : @zen.OpenCodeZenConfig,
  inspector : ((@posoco.StreamAccumulator, Bool) -> @zen.StreamVerdict)?,
) -> &@posoco.ModelPort {
  let wire_port : &@posoco.ModelPort = @zen.opencode_anchored_compact_port(
    config,
    inspector~,
  )
  GoRateLimitModelPort(
    inner=wire_port,
    base_url=config.base_url,
    api_key=config.api_key,
    extra_headers=config.extra_headers,
  )
}

///|
/// Build one catalog slot for a Go model: the anchored-compact wire port
/// wrapped in the rate-limit recovery decorator, and — on the `deepseek*`
/// chat-completions slots — the DeepSeek contract outermost, so request-side
/// ordering and the reset enrichment apply on every attempt.
fn go_catalog_slot(
  config : @zen.OpenCodeZenConfig,
  surface : @zen.ZenReasoningSurface?,
  api_key : &@llm.ApiKeyFactory,
  policy~ : @ds.DeepSeekPolicy? = None,
  ctx~ : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> @llm.ModelSlot {
  let applies = go_deepseek_applies(config)
  let inspector : ((@posoco.StreamAccumulator, Bool) -> @zen.StreamVerdict)? = match
    policy {
    Some(p) if applies => Some(go_deepseek_inspector(p, ctx))
    _ => None
  }
  let retry_at_low : (() -> &@posoco.ModelPort)? = if applies &&
    config.thinking_efforts.contains("low") {
    let low_config = config.with_reasoning_effort("low") catch {
      err =>
        abort("OpenCode Go catalog effort rebuild failed: " + err.to_string())
    }
    Some(fn() { go_rate_limited_port(low_config, inspector) })
  } else {
    None
  }
  let rate_port = go_rate_limited_port(config, inspector)
  let port : &@posoco.ModelPort = match policy {
    Some(p) if applies =>
      @ds.deepseek_policy_port(
        inner=rate_port,
        policy=p,
        retry_at_low~,
        inject_convergence=true,
        ctx~,
        source="posoco_ext_opencode_go",
      )
    _ => rate_port
  }
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
      go_catalog_slot(rebuilt_config, surface, api_key, policy~, ctx~)
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
      go_catalog_slot(rebuilt_config, surface, api_key, policy~, ctx~)
    }),
    rebuild_on_credential=Some(fn(credential) {
      match go_oauth_session(credential) {
        Some(session) => {
          let base_url = match session.api_base {
            Some(value) => value
            None => config.base_url
          }
          let rebuilt_config : @zen.OpenCodeZenConfig = {
            ..config,
            api_key: session.access_token,
            base_url,
            extra_headers: go_extra_headers(session.org_id),
            bearer_auth: true,
          }
          go_catalog_slot(rebuilt_config, surface, api_key, policy~, ctx~)
        }
        None => go_catalog_slot(config, surface, api_key, policy~, ctx~)
      }
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
        extra_headers=base.extra_headers,
        bearer_auth=base.bearer_auth,
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
        extra_headers=base.extra_headers,
        bearer_auth=base.bearer_auth,
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
  policy~ : @ds.DeepSeekPolicy? = None,
  ctx~ : @devkit.ExtContext = @devkit.ExtContext::default(),
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
        policy~,
        ctx~,
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
  policy~ : @ds.DeepSeekPolicy? = None,
  ctx~ : @devkit.ExtContext = @devkit.ExtContext::default(),
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
    slots.push(go_catalog_slot(config, surface, api_key, policy~, ctx~))
  }
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id=go_provider_id,
    slots~,
    capabilities=["chat", "streaming", "api_key"],
  )
}
