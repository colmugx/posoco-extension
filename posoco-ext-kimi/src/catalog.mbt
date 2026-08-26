///|
/// Rebuild one Kimi slot while preserving both credential and effort hooks.
/// Keeping both hooks in one helper prevents an OAuth login from silently
/// dropping the provider's effort capabilities.
fn kimi_catalog_slot(
  config : KimiConfig,
  ctx : @devkit.ExtContext,
  oauth : &@oauth.OAuthProvider,
  api_key : &@llm.ApiKeyFactory,
  label? : String? = None,
  context_window? : Int? = None,
  capabilities? : Array[String] = [],
  default_effort? : String? = None,
) -> @llm.ModelSlot {
  let port : &@posoco.ModelPort = KimiModelPort(config, ctx~)
  let slot_id = "kimi/" + config.model
  let rebuild_on_effort : ((String) -> @llm.ModelSlot)? = if config.thinking_efforts.is_empty() {
    None
  } else {
    Some(fn(effort) {
      let refreshed = config.with_reasoning_effort(effort) catch {
        err => abort("Kimi catalog effort rebuild failed: " + err.to_string())
      }
      kimi_catalog_slot(
        refreshed,
        ctx,
        oauth,
        api_key,
        label~,
        context_window~,
        capabilities~,
        default_effort~,
      )
    })
  }
  @llm.ModelSlot::ModelSlot(
    id=slot_id,
    label=match label {
      Some(value) => value
      None => "Kimi / " + config.model
    },
    provider_id="kimi",
    model_id=config.model,
    port~,
    oauth=Some(oauth),
    api_key=Some(api_key),
    thinking_efforts=config.thinking_efforts,
    context_window~,
    capabilities~,
    default_effort~,
    rebuild_on_credential=Some(fn(credential) {
      let refreshed = KimiConfig(
        credential.access_token,
        model=config.model,
        base_url=kimi_oauth_api_base(),
        endpoint_prefix=config.endpoint_prefix,
        reasoning_effort=config.reasoning_effort,
        thinking_efforts=Some(config.thinking_efforts),
        context_window=config.context_window,
        supports_images=config.supports_images,
      )
      kimi_catalog_slot(
        refreshed,
        ctx,
        oauth,
        api_key,
        label~,
        context_window~,
        capabilities~,
        default_effort~,
      )
    }),
    rebuild_on_api_key=Some(fn(credential) {
      let refreshed = KimiConfig(
        credential.secret,
        model=config.model,
        base_url=config.base_url,
        endpoint_prefix=config.endpoint_prefix,
        reasoning_effort=config.reasoning_effort,
        thinking_efforts=Some(config.thinking_efforts),
        context_window=config.context_window,
        supports_images=config.supports_images,
      )
      kimi_catalog_slot(
        refreshed,
        ctx,
        oauth,
        api_key,
        label~,
        context_window~,
        capabilities~,
        default_effort~,
      )
    }),
    rebuild_on_effort~,
  )
}

///|
/// Build one slot from a live provider model descriptor while retaining the
/// configured model's requested effort whenever the server still advertises
/// it.  A catalog refresh therefore cannot silently switch the active model
/// to a hardcoded family default.
fn kimi_catalog_slot_from_info(
  base_config : KimiConfig,
  info : KimiModelInfo,
  ctx : @devkit.ExtContext,
  oauth : &@oauth.OAuthProvider,
  api_key : &@llm.ApiKeyFactory,
) -> @llm.ModelSlot {
  let selected_effort = if info.thinking_efforts.is_empty() {
    ""
  } else if info.thinking_efforts.contains(base_config.reasoning_effort) {
    base_config.reasoning_effort
  } else {
    match info.default_effort {
      Some(value) => value
      None => info.thinking_efforts[0]
    }
  }
  let config = KimiConfig(
    base_config.api_key,
    model=info.id,
    base_url=base_config.base_url,
    endpoint_prefix=base_config.endpoint_prefix,
    reasoning_effort=selected_effort,
    thinking_efforts=Some(info.thinking_efforts),
    context_window=Some(info.context_window),
    supports_images=info.capabilities.contains("image_in"),
  )
  kimi_catalog_slot(
    config,
    ctx,
    oauth,
    api_key,
    label=Some(info.display_name),
    context_window=Some(info.context_window),
    capabilities=info.capabilities,
    default_effort=info.default_effort,
  )
}

///|
/// Move the configured model to the front while retaining server order for
/// all other entries.  Router selection is declaration-order based, so this
/// keeps provider settings.model active after an explicit refresh.
fn kimi_preferred_models(
  models : Array[KimiModelInfo],
  preferred_id : String,
) -> Array[KimiModelInfo] {
  let result : Array[KimiModelInfo] = []
  let mut preferred : KimiModelInfo? = None
  for model in models {
    if model.id == preferred_id {
      preferred = Some(model)
    } else {
      result.push(model)
    }
  }
  match preferred {
    Some(model) => {
      let ordered : Array[KimiModelInfo] = [model]
      ordered.append(result)
      ordered
    }
    None => models
  }
}

///|
/// Build a provider-owned Kimi model catalog.

///|
/// Kimi exposes chat and streaming chat only. In particular, this catalog
/// intentionally does not advertise FIM or prefix completion capabilities.
pub fn KimiModelPort::model_catalog(
  self : KimiModelPort,
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  let oauth_impl = KimiOAuth::KimiOAuth()
  let oauth : &@oauth.OAuthProvider = oauth_impl
  let api_key_impl = KimiProvider(ctx=self.ctx)
  let api_key : &@llm.ApiKeyFactory = api_key_impl
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id="kimi",
    slots=[kimi_catalog_slot(self.config, self.ctx, oauth, api_key)],
    capabilities=["chat", "streaming", "reasoning", "api_key", "oauth"],
  )
}

///|
/// Build a catalog from the provider's authenticated `/models` response.
pub fn KimiModelPort::model_catalog_from_models(
  self : KimiModelPort,
  models : Array[KimiModelInfo],
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  if models.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_kimi",
      detail="models endpoint returned an empty catalog",
    )
  }
  let oauth_impl = KimiOAuth::KimiOAuth()
  let oauth : &@oauth.OAuthProvider = oauth_impl
  let api_key_impl = KimiProvider(ctx=self.ctx)
  let api_key : &@llm.ApiKeyFactory = api_key_impl
  let slots : Array[@llm.ModelSlot] = []
  for info in kimi_preferred_models(models, self.config.model) {
    slots.push(
      kimi_catalog_slot_from_info(self.config, info, self.ctx, oauth, api_key),
    )
  }
  @llm.ProviderModelCatalog::ProviderModelCatalog(provider_id="kimi", slots~, capabilities=[
    "chat", "streaming", "reasoning", "api_key", "oauth",
  ])
}
