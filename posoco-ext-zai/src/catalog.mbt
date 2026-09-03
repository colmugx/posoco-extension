///|
fn zai_slot_efforts(config : ZaiConfig) -> Array[String] {
  if config.thinking_efforts.is_empty() {
    return []
  }
  let efforts : Array[String] = ["off"]
  efforts.append(config.thinking_efforts.copy())
  efforts
}

///|
fn zai_effort_label(config : ZaiConfig) -> String {
  if config.reasoning_effort == "" {
    "off"
  } else {
    config.reasoning_effort
  }
}

///|
fn zai_catalog_slot(
  config : ZaiConfig,
  ctx : @devkit.ExtContext,
  identity : ZaiCatalogIdentity,
  api_key : &@llm.ApiKeyFactory,
) -> @llm.ModelSlot {
  let port : &@posoco.ModelPort = ZaiModelPort(config, ctx~)
  let slot_efforts = zai_slot_efforts(config)
  let default_effort = if slot_efforts.is_empty() {
    None
  } else {
    Some(zai_effort_label(config))
  }
  let rebuild_on_effort : ((String) -> @llm.ModelSlot)? = if slot_efforts.is_empty() {
    None
  } else {
    Some(fn(effort) {
      let rebuilt = config.with_reasoning_effort(
        effort,
        manifest_id=identity.manifest_id,
      ) catch {
        err => abort("zai catalog effort rebuild failed: " + err.to_string())
      }
      zai_catalog_slot(rebuilt, ctx, identity, api_key)
    })
  }
  @llm.ModelSlot::ModelSlot(
    id=identity.provider_id + "/" + config.model,
    label=identity.label_prefix + " / " + config.model,
    provider_id=identity.provider_id,
    model_id=config.model,
    port~,
    api_key=Some(api_key),
    thinking_efforts=slot_efforts,
    default_effort~,
    rebuild_on_api_key=Some(fn(credential) {
      // The credential is authoritative for the endpoint only when it names a
      // known platform (the /login flow records it); otherwise the slot keeps
      // its current endpoint and just swaps the secret.
      let rebuilt = match identity.endpoint_for_credential {
        Some(resolve) =>
          match resolve(credential) {
            Some((base_url, endpoint_prefix)) =>
              ZaiConfig::for_model(
                credential.secret,
                config.model,
                base_url~,
                endpoint_prefix~,
              )
            None =>
              ZaiConfig::for_model(
                credential.secret,
                config.model,
                base_url=config.base_url,
                endpoint_prefix=config.endpoint_prefix,
              )
          }
        None =>
          ZaiConfig::for_model(
            credential.secret,
            config.model,
            base_url=config.base_url,
            endpoint_prefix=config.endpoint_prefix,
          )
      }
      let with_effort = if config.reasoning_effort == "" {
        rebuilt
      } else {
        rebuilt.with_reasoning_effort(
          config.reasoning_effort,
          manifest_id=identity.manifest_id,
        ) catch {
          err => abort("zai catalog api-key rebuild failed: " + err.to_string())
        }
      }
      zai_catalog_slot(with_effort, ctx, identity, api_key)
    }),
    rebuild_on_effort~,
  )
}

///|
/// Presentation and rebuild identity of a GLM catalog: which provider id the
/// slots advertise, how they are labeled, and (optionally) how a fresh
/// credential remaps the endpoint. Composers that always keep their endpoint
/// leave `endpoint_for_credential` empty.
pub(all) struct ZaiCatalogIdentity {
  provider_id : String
  label_prefix : String
  manifest_id : String
  endpoint_for_credential : ((@oauth.ApiKeyCredential) -> (String, String)?)?
}

///|
pub fn ZaiCatalogIdentity::ZaiCatalogIdentity(
  provider_id~ : String,
  label_prefix~ : String,
  manifest_id~ : String,
  endpoint_for_credential~ : ((@oauth.ApiKeyCredential) -> (String, String)?)?,
) -> ZaiCatalogIdentity {
  { provider_id, label_prefix, manifest_id, endpoint_for_credential, }
}

///|
/// Order a model-id list with the configured (preferred) id first while
/// preserving the list's order for the rest. A missing preferred id keeps
/// the list unchanged — the configured model is not invented.
fn zai_preferred_ids(
  ids : Array[String],
  preferred_id : String,
) -> Array[String] {
  if ids.contains(preferred_id) {
    let ordered : Array[String] = [preferred_id]
    for id in ids {
      if id != preferred_id {
        ordered.push(id)
      }
    }
    ordered
  } else {
    ids
  }
}

///|
/// Catalog from an explicit model-id list (live `/models` discovery or the
/// host's disk cache). The configured model keeps its settings-resolved
/// config; every other id gets that model's default config. An empty list is
/// a typed composition failure — an empty catalog is never announced.
pub fn zai_model_catalog_from_ids(
  ids : Array[String],
  config : ZaiConfig,
  ctx : @devkit.ExtContext,
  identity : ZaiCatalogIdentity,
  api_key : &@llm.ApiKeyFactory,
  capabilities? : Array[String] = ["chat", "streaming", "api_key"],
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  if ids.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id=identity.manifest_id,
      detail="models list is empty",
    )
  }
  let slots : Array[@llm.ModelSlot] = []
  for id in zai_preferred_ids(ids, config.model) {
    let slot_config = if id == config.model {
      config
    } else {
      ZaiConfig::for_model(
        config.api_key,
        id,
        base_url=config.base_url,
        endpoint_prefix=config.endpoint_prefix,
      )
    }
    slots.push(zai_catalog_slot(slot_config, ctx, identity, api_key))
  }
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id=identity.provider_id,
    slots~,
    capabilities~,
  )
}

///|
/// Preset catalog: one slot per known GLM model. Used when no credential is
/// discoverable yet and as the offline fallback when the host has no cached
/// model list; the configured model is ordered first.
pub fn zai_model_catalog(
  config : ZaiConfig,
  ctx : @devkit.ExtContext,
  identity : ZaiCatalogIdentity,
  api_key : &@llm.ApiKeyFactory,
  capabilities? : Array[String] = ["chat", "streaming", "api_key"],
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  let ids : Array[String] = []
  for info in zai_models() {
    ids.push(info.id)
  }
  zai_model_catalog_from_ids(ids, config, ctx, identity, api_key, capabilities~)
}

///|
/// Catalog for this port under the direct-API identity.
pub fn ZaiModelPort::model_catalog(
  self : ZaiModelPort,
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  let api_key_impl = ZaiProvider(ctx=self.ctx)
  let api_key : &@llm.ApiKeyFactory = api_key_impl
  zai_model_catalog(
    self.config,
    self.ctx,
    ZaiCatalogIdentity::ZaiCatalogIdentity(
      provider_id="zai",
      label_prefix="Z.ai",
      manifest_id="posoco_ext_zai",
      endpoint_for_credential=None,
    ),
    api_key,
  )
}
