///|
/// Provider-owned configuration source and catalog contribution for the
/// OpenRouter `/api/v1/chat/completions` endpoint.
///
/// One `OpenRouterProvider` instance serves exactly one provider id
/// ("openrouter", fixed — unlike the generic openai-compatible adapter this
/// extension is purpose-built for OpenRouter's reasoning surface). It owns:
/// settings interpretation, ApiKey-only credential resolution, and the
/// single-model slot with its rebuild hooks. The host (cetas-core) calls
/// `build` with an opaque settings object and receives a ready catalog.

///|
pub(all) struct OpenRouterProvider {
  ctx : @devkit.ExtContext
}

///|
/// Construct the provider factory. The optional `ctx` is carried for debug
/// logging at composition seams.
///
/// Example:
/// ```moonbit nocheck
/// let provider = OpenRouterProvider()
/// let factory : &@llm.ProviderFactory = provider
/// let source = @llm.ProviderConfigSource::ProviderConfigSource(
///   settings=Some(
///     Json::object(
///       Map::from_array([
///         ("model", Json::string("anthropic/claude-3.7-sonnet")),
///         ("api_key", Json::string("sk-or-v1-test")),
///       ]),
///     ),
///   ),
/// )
/// match factory.build(source) {
///   @llm.ProviderBuildResult::Ready(catalog) =>
///     inspect(
///       catalog.slots()[0].id,
///       content="openrouter/anthropic/claude-3.7-sonnet",
///     )
///   @llm.ProviderBuildResult::Unconfigured => fail("expected a ready catalog")
/// }
/// ```
pub fn OpenRouterProvider::OpenRouterProvider(
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> OpenRouterProvider {
  { ctx, }
}

///|
fn openrouter_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openrouter",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail="setting must be a string: " + key,
      )
  }
}

///|
/// Validate declared effort entries: non-empty, unique, and never the reserved
/// selector words "off"/"on" (those belong to the toggle vocabulary, never to a
/// declared level). The values pass through verbatim — the server owns the
/// valid level names, this adapter only owns their plumbing.
fn openrouter_effort_array_value(
  key : String,
  values : Array[Json],
) -> Array[String] raise @posoco.CompositionError {
  let efforts : Array[String] = []
  for value in values {
    match value {
      Json::String(effort) if effort.length() > 0 => efforts.push(effort)
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openrouter",
          detail=key + " entries must be non-empty strings",
        )
    }
  }
  let seen : Map[String, Unit] = Map::from_array([])
  for effort in efforts {
    if effort == "off" || effort == "on" {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail=key +
          " reserves 'off'/'on' for the thinking toggle; declare explicit levels instead",
      )
    }
    if seen.contains(effort) {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail=key + " entries must be unique: " + effort,
      )
    }
    seen[effort] = ()
  }
  efforts
}

///|
/// Parse one settings key as the declared effort array. `None` means the key
/// is absent (the plain off/on toggle); a present but non-array value is a
/// typed composition failure.
fn openrouter_setting_effort_array(
  source : @llm.ProviderConfigSource,
  key : String,
) -> Array[String]? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::Array(values)) =>
      Some(openrouter_effort_array_value(key, values))
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail=key + " must be an array of strings",
      )
  }
}

///|
/// The picker-facing effort list: "off" plus every declared level, or just the
/// on/off toggle when the settings declare no levels. Every OpenRouter model
/// gets at least the toggle — no conventional level set is ever fabricated.
fn openrouter_slot_efforts(config : OpenRouterConfig) -> Array[String] {
  if config.thinking_efforts.is_empty() {
    return ["off", "on"]
  }
  let efforts : Array[String] = ["off"]
  efforts.append(config.thinking_efforts.copy())
  efforts
}

///|
/// The picker-facing label of the config's current state.
fn openrouter_effort_label(config : OpenRouterConfig) -> String {
  if config.thinking == false {
    "off"
  } else {
    match config.reasoning_effort {
      Some(effort) => effort
      None => "on"
    }
  }
}

///|
/// Build the provider's one model slot from a config. All rebuild hooks
/// funnel back here so the rebuilt slot is identical in shape.
fn openrouter_catalog_slot(
  config : OpenRouterConfig,
  api_key : &@llm.ApiKeyFactory,
) -> @llm.ModelSlot {
  let slot_id = "openrouter/" + config.model
  let label = "openrouter / " + config.model
  let slot_efforts = openrouter_slot_efforts(config)
  let default_effort = Some(openrouter_effort_label(config))
  let port : &@posoco.ModelPort = OpenRouterModelPort(config)
  let rebuild_on_effort : ((String) -> @llm.ModelSlot)? = Some(fn(effort) {
    let rebuilt_config = config.with_reasoning_effort(effort) catch {
      err =>
        abort("openrouter catalog effort rebuild failed: " + err.to_string())
    }
    openrouter_catalog_slot(rebuilt_config, api_key)
  })
  @llm.ModelSlot::ModelSlot(
    id=slot_id,
    label~,
    provider_id="openrouter",
    model_id=config.model,
    port~,
    api_key=Some(api_key),
    thinking_efforts=slot_efforts,
    context_window=config.context_window,
    capabilities=["chat", "streaming", "reasoning", "api_key"],
    default_effort~,
    rebuild_on_api_key=Some(fn(credential) {
      let rebuilt_config = OpenRouterConfig(
        credential.secret,
        model=config.model,
        base_url=config.base_url,
        thinking=config.thinking,
        reasoning_effort=config.reasoning_effort,
        thinking_efforts=config.thinking_efforts,
        context_window=config.context_window,
        compact_threshold=config.compact_threshold,
        http_referer=config.http_referer,
        title=config.title,
      )
      openrouter_catalog_slot(rebuilt_config, api_key)
    }),
    rebuild_on_effort~,
  )
}

///|
pub impl @llm.ProviderFactory for OpenRouterProvider with fn provider_id(
  _self : OpenRouterProvider,
) -> String {
  "openrouter"
}

///|
pub impl @llm.ProviderFactory for OpenRouterProvider with fn credential_id(
  _self : OpenRouterProvider,
) -> String {
  "openrouter"
}

///|
/// Resolve the API key from the credential store or settings, or report that
/// the provider is unconfigured. Shared by `build` and `refresh` so the two
/// paths apply identical credential rules.
fn openrouter_resolve_api_key(
  source : @llm.ProviderConfigSource,
) -> String? raise @posoco.CompositionError {
  let credential = source.effective_credential("openrouter")
  match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail="OAuth credential is not supported for provider openrouter",
      )
    Some(@oauth.ProviderCredential::ApiKey(credential)) =>
      Some(credential.secret)
    None => openrouter_setting_string(source, "api_key")
  }
}

///|
/// Resolve the base URL, applying the conventional default when settings
/// omit it. Shared by `build` and `refresh`.
fn openrouter_resolve_base_url(
  source : @llm.ProviderConfigSource,
) -> String raise @posoco.CompositionError {
  match openrouter_setting_string(source, "base_url") {
    Some(value) => value
    None => "https://openrouter.ai/api/v1"
  }
}

///|
/// Alias so `refresh` (refresh_native_js.mbt) reads settings through the
/// same typed helper as `build` without re-deriving the error shape.
fn openrouter_resolve_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  openrouter_setting_string(source, key)
}

///|
/// Build a catalog snapshot for this provider without any network request.
///
/// Priority order: host-cached discovery records (a previous refresh's
/// projection) expand to the full multi-slot catalog offline, so restarts
/// announce the complete list immediately after a login+refresh even with no
/// settings at all; otherwise an explicit settings `model` builds the single
/// static slot (its declared `thinking_efforts`/`context_window` govern only
/// this pre-discovery slot — after discovery the models' own metadata owns
/// the surface); otherwise Unconfigured — the login-first flow writes a
/// credential before any settings exist, and there is no OpenRouter default
/// model to fabricate. Malformed configured values (wrong types, out-of-range
/// numbers) remain typed composition failures.
pub impl @llm.ProviderFactory for OpenRouterProvider with fn build(
  self : OpenRouterProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let api_key = match openrouter_resolve_api_key(source) {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let base_url = openrouter_resolve_base_url(source)
  let http_referer = openrouter_setting_string(source, "http_referer")
  let title = openrouter_setting_string(source, "title")
  let api_key_factory : &@llm.ApiKeyFactory = OpenRouterApiKeyFactory(
    ctx=self.ctx,
  )
  match parse_cached_openrouter_models(source.cached_models) {
    Some(models) => {
      let preferred = match openrouter_setting_string(source, "model") {
        Some(value) => value
        None => ""
      }
      let catalog = openrouter_model_catalog(
        api_key,
        base_url,
        models,
        preferred,
        api_key_factory,
        http_referer~,
        title~,
      )
      return @llm.ProviderBuildResult::Ready(catalog)
    }
    None => ()
  }
  let model = match openrouter_setting_string(source, "model") {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let declared_efforts = match
    openrouter_setting_effort_array(source, "thinking_efforts") {
    Some(values) => values
    None => []
  }
  let context_window = match source.setting("context_window") {
    None => None
    Some(Json::Number(value, ..)) => {
      let window = value.to_int()
      if window.to_double() != value || window <= 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openrouter",
          detail="context_window must be a positive integer",
        )
      }
      Some(window)
    }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail="context_window must be a positive integer",
      )
  }
  let compact_threshold = match source.setting("compact_threshold") {
    None => None
    Some(Json::Number(value, ..)) => {
      if value <= 0.0 || value > 1.0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openrouter",
          detail="compact_threshold must be a fraction in (0, 1] (e.g. 0.85)",
        )
      }
      if context_window is None {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openrouter",
          detail="compact_threshold requires context_window",
        )
      }
      Some(value)
    }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openrouter",
        detail="compact_threshold must be a number in (0, 1]",
      )
  }
  // Declared levels select the initial config state: the first level is the
  // default effort. No declaration means the plain off/on toggle, and the
  // config starts with thinking off — the endpoint applies its own default.
  let config = match declared_efforts.length() {
    0 =>
      OpenRouterConfig(
        api_key,
        model~,
        base_url~,
        context_window~,
        compact_threshold~,
        http_referer~,
        title~,
      )
    _ =>
      OpenRouterConfig(
        api_key,
        model~,
        base_url~,
        thinking=true,
        reasoning_effort=Some(declared_efforts[0]),
        thinking_efforts=declared_efforts,
        context_window~,
        compact_threshold~,
        http_referer~,
        title~,
      )
  }
  @llm.ProviderBuildResult::Ready(
    @llm.ProviderModelCatalog::ProviderModelCatalog(
      provider_id="openrouter",
      slots=[openrouter_catalog_slot(config, api_key_factory)],
      capabilities=["chat", "streaming", "reasoning", "api_key"],
    ),
  )
}

///|
pub impl @llm.RefreshableProviderFactory for OpenRouterProvider with fn provider_id(
  _self : OpenRouterProvider,
) -> String {
  "openrouter"
}

///|
/// Live catalog refresh lives in refresh_native_js.mbt (it calls
/// `fetch_openrouter_models`, which drives `@http` — native+js only). On
/// wasm/wasm-gc a fallback impl in refresh_wasm_fallback.mbt raises a clear
/// `CompositionError` so the trait is fully satisfied on every backend.

///|
/// Provider-owned API-key login. The host supplies a provider-neutral secret
/// prompt; validation and credential shape stay in this extension.
pub(all) struct OpenRouterApiKeyFactory {
  ctx : @devkit.ExtContext
}

///|
pub fn OpenRouterApiKeyFactory::OpenRouterApiKeyFactory(
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> OpenRouterApiKeyFactory {
  { ctx, }
}

///|
pub impl @llm.ApiKeyFactory for OpenRouterApiKeyFactory with fn provider_id(
  _self : OpenRouterApiKeyFactory,
) -> String {
  "openrouter"
}

///|
pub impl @llm.ApiKeyFactory for OpenRouterApiKeyFactory with fn credential_id(
  _self : OpenRouterApiKeyFactory,
) -> String {
  "openrouter"
}

///|
pub impl @llm.ApiKeyFactory for OpenRouterApiKeyFactory with fn login(
  _self : OpenRouterApiKeyFactory,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="OpenRouter API key"),
  )
  if secret.length() == 0 {
    raise @oauth.OAuthError::ParseError("OpenRouter API key must not be empty")
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}
