///|
/// Provider-owned configuration source and catalog contribution for any
/// standard OpenAI-compatible endpoint.
///
/// One `OpenAICompatibleProvider` instance is scoped to exactly one provider
/// id (set at construction). The host (cetas-core) constructs one instance per
/// custom settings id; this adapter never reads the settings map itself and
/// never decides which ids it serves. It owns only: Chat Completions request
/// shape, response decoding, optional top-level reasoning_effort, and API-key
/// login for its one id.

///|
pub(all) struct OpenAICompatibleProvider {
  provider_id : String
  ctx : @devkit.ExtContext
}

///|
/// Construct a provider scoped to `provider_id`. The id is opaque to this
/// adapter — it is used only for catalog labeling and the credential store
/// key. The host decides which ids route here.
pub fn OpenAICompatibleProvider::new(
  provider_id : String,
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> OpenAICompatibleProvider {
  { provider_id, ctx }
}

///|
fn oai_compat_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openai_compatible",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openai_compatible",
        detail="setting must be a string: " + key,
      )
  }
}

///|
/// Keep URL parsing in the provider extension. The host passes one opaque
/// base_url string; this adapter decides how its path prefix maps to chat. The
/// convention follows DeepSeek: split "://host[/prefix]" into (base, prefix),
/// stripping any trailing "/" on the prefix.
fn oai_compat_endpoint_parts(url : String) -> (String, String) {
  match url.find("://") {
    None => (url, "")
    Some(protocol_end) => {
      let after_start = protocol_end + 3
      let after = url.sub(start=after_start)
      match after.find("/") {
        None => (url, "")
        Some(slash) => {
          let host_end = after_start + slash
          let clean = url.sub(end=host_end).to_owned()
          let prefix = after.sub(start=slash).to_owned()
          match prefix.strip_suffix("/") {
            Some(value) => (clean, value.to_owned())
            None => (clean, prefix)
          }
        }
      }
    }
  }
}

///|
/// Parse the optional `reasoning_efforts` settings array. Each entry must be a
/// non-empty string; the adapter passes the values through verbatim (the
/// server owns the valid level names, this adapter only owns their plumbing).
fn oai_compat_setting_efforts(
  source : @llm.ProviderConfigSource,
) -> Array[String] raise @posoco.CompositionError {
  match source.setting("reasoning_efforts") {
    None => []
    Some(Json::Array(values)) => {
      let efforts : Array[String] = []
      for value in values {
        match value {
          Json::String(effort) if effort.length() > 0 => efforts.push(effort)
          _ =>
            raise @posoco.CompositionError::ManifestSchemaError(
              manifest_id="posoco_ext_openai_compatible",
              detail="reasoning_efforts entries must be non-empty strings",
            )
        }
      }
      efforts
    }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openai_compatible",
        detail="reasoning_efforts must be an array of strings",
      )
  }
}

///|
/// The picker-facing effort list: an implicit leading "off" (omit the wire
/// field) plus every declared level. Empty declared list means no selector.
fn oai_compat_slot_efforts(config : OpenAICompatibleConfig) -> Array[String] {
  if config.thinking_efforts.is_empty() {
    return []
  }
  let efforts : Array[String] = ["off"]
  efforts.append(config.thinking_efforts.copy())
  efforts
}

///|
/// The picker-facing label of the config's current effort.
fn oai_compat_effort_label(config : OpenAICompatibleConfig) -> String {
  if config.reasoning_effort == "" {
    "off"
  } else {
    config.reasoning_effort
  }
}

///|
/// Build the provider's one model slot from a config. Custom endpoints share
/// the "custom" display group so the picker tabs them together while the slot
/// keeps its real provider_id for credentials and routing. All rebuild hooks
/// funnel back here so the rebuilt slot is identical in shape.
fn oai_compat_catalog_slot(
  provider_id : String,
  config : OpenAICompatibleConfig,
) -> @llm.ModelSlot {
  let slot_id = provider_id + "/" + config.model
  let label = provider_id + " / " + config.model
  let slot_efforts = oai_compat_slot_efforts(config)
  let default_effort = if slot_efforts.is_empty() {
    None
  } else {
    Some(oai_compat_effort_label(config))
  }
  let port : &@posoco.ModelPort = OpenAICompatibleModelPort::new(
    provider_id, config,
  )
  let api_key : &@llm.ApiKeyFactory = OpenAICompatibleProvider::new(provider_id)
  let rebuild_on_effort : ((String) -> @llm.ModelSlot)? = if slot_efforts.is_empty() {
    None
  } else {
    Some(fn(effort) {
      let rebuilt_config = config.with_reasoning_effort(effort) catch {
        err =>
          abort(
            "openai-compatible catalog effort rebuild failed: " +
            err.to_string(),
          )
      }
      oai_compat_catalog_slot(provider_id, rebuilt_config)
    })
  }
  @llm.ModelSlot::ModelSlot(
    id=slot_id,
    label~,
    provider_id~,
    model_id=config.model,
    port~,
    api_key=Some(api_key),
    thinking_efforts=slot_efforts,
    capabilities=["chat", "streaming", "api_key"],
    default_effort~,
    display_group=Some("custom"),
    rebuild_on_api_key=Some(fn(credential) {
      let rebuilt_config = OpenAICompatibleConfig::new(
        credential.secret,
        base_url=config.base_url,
        model=config.model,
        endpoint_prefix=config.endpoint_prefix,
        reasoning_effort=config.reasoning_effort,
        thinking_efforts=config.thinking_efforts,
      )
      oai_compat_catalog_slot(provider_id, rebuilt_config)
    }),
    rebuild_on_effort~,
  )
}

///|
pub impl @llm.ProviderFactory for OpenAICompatibleProvider with fn provider_id(
  self : OpenAICompatibleProvider,
) -> String {
  self.provider_id
}

///|
pub impl @llm.ProviderFactory for OpenAICompatibleProvider with fn credential_id(
  self : OpenAICompatibleProvider,
) -> String {
  self.provider_id
}

///|
/// Build a catalog snapshot for this provider's one id. Missing api_key or
/// base_url is a normal Unconfigured state (the host shows no slot); malformed
/// configured values are typed composition failures.
pub impl @llm.ProviderFactory for OpenAICompatibleProvider with fn build(
  self : OpenAICompatibleProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let credential = source.effective_credential(self.provider_id)
  let api_key = match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openai_compatible",
        detail="OAuth credential is not supported for provider " +
          self.provider_id,
      )
    Some(@oauth.ProviderCredential::ApiKey(credential)) => credential.secret
    None =>
      match oai_compat_setting_string(source, "api_key") {
        Some(value) => value
        None => return @llm.ProviderBuildResult::Unconfigured
      }
  }
  let base_url = match oai_compat_setting_string(source, "base_url") {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let model = match oai_compat_setting_string(source, "model") {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let endpoint_prefix = match
    oai_compat_setting_string(source, "endpoint_prefix") {
    Some(value) => value
    None => ""
  }
  let reasoning_effort = match
    oai_compat_setting_string(source, "reasoning_effort") {
    Some(value) => value
    None => ""
  }
  let thinking_efforts = oai_compat_setting_efforts(source)
  if reasoning_effort != "" &&
    !thinking_efforts.is_empty() &&
    !thinking_efforts.contains(reasoning_effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_openai_compatible",
      detail="reasoning_effort is not one of reasoning_efforts: " +
        reasoning_effort,
    )
  }
  let config = OpenAICompatibleConfig::new(
    api_key,
    base_url~,
    model~,
    endpoint_prefix~,
    reasoning_effort~,
    thinking_efforts~,
  )
  let port = OpenAICompatibleModelPort::new(self.provider_id, config)
  @llm.ProviderBuildResult::Ready(port.model_catalog())
}

///|
/// Build a provider catalog from an already-resolved config. The slot exposes
/// an api-key rebuild hook so `/login <provider_id>` can swap the secret and
/// the router rebuilds the slot without recomposing the agent.
pub fn OpenAICompatibleModelPort::model_catalog(
  self : OpenAICompatibleModelPort,
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id=self.provider_id,
    slots=[oai_compat_catalog_slot(self.provider_id, self.config)],
    capabilities=["chat", "streaming", "api_key"],
  )
}

///|
/// Provider-owned API-key login. The host supplies a provider-neutral secret
/// prompt; validation and credential shape stay in this extension.
pub impl @llm.ApiKeyFactory for OpenAICompatibleProvider with fn provider_id(
  self : OpenAICompatibleProvider,
) -> String {
  self.provider_id
}

///|
pub impl @llm.ApiKeyFactory for OpenAICompatibleProvider with fn credential_id(
  self : OpenAICompatibleProvider,
) -> String {
  self.provider_id
}

///|
pub impl @llm.ApiKeyFactory for OpenAICompatibleProvider with fn login(
  self : OpenAICompatibleProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="API key for " + self.provider_id),
  )
  if secret.length() == 0 {
    raise @oauth.OAuthError::ParseError(
      "API key must not be empty for provider " + self.provider_id,
    )
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}
