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
/// Validate declared effort entries: non-empty, unique, and never the reserved
/// selector words "off"/"on" (those belong to the toggle vocabulary, never to a
/// declared level). The values pass through verbatim — the server owns the
/// valid level names, this adapter only owns their plumbing.
fn oai_compat_effort_array_value(
  key : String,
  values : Array[Json],
) -> Array[String] raise @posoco.CompositionError {
  let efforts : Array[String] = []
  for value in values {
    match value {
      Json::String(effort) if effort.length() > 0 => efforts.push(effort)
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openai_compatible",
          detail=key + " entries must be non-empty strings",
        )
    }
  }
  let seen : Map[String, Unit] = Map::from_array([])
  for effort in efforts {
    if effort == "off" || effort == "on" {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openai_compatible",
        detail=key +
          " reserves 'off'/'on' for the thinking toggle; declare explicit levels instead",
      )
    }
    if seen.contains(effort) {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openai_compatible",
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
fn oai_compat_setting_effort_array(
  source : @llm.ProviderConfigSource,
  key : String,
) -> Array[String]? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::Array(values)) =>
      Some(oai_compat_effort_array_value(key, values))
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openai_compatible",
        detail=key + " must be an array of strings",
      )
  }
}

///|
/// The picker-facing effort list: "off" plus every declared level, or just the
/// on/off toggle when the settings declare no levels. Every custom endpoint
/// gets at least the toggle — no conventional level set is ever fabricated.
fn oai_compat_slot_efforts(config : OpenAICompatibleConfig) -> Array[String] {
  if config.thinking_efforts.is_empty() {
    return ["off", "on"]
  }
  let efforts : Array[String] = ["off"]
  efforts.append(config.thinking_efforts.copy())
  efforts
}

///|
/// The picker-facing label of the config's current state.
fn oai_compat_effort_label(config : OpenAICompatibleConfig) -> String {
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
  let default_effort = Some(oai_compat_effort_label(config))
  let port : &@posoco.ModelPort = OpenAICompatibleModelPort::new(
    provider_id, config,
  )
  let api_key : &@llm.ApiKeyFactory = OpenAICompatibleProvider::new(provider_id)
  let rebuild_on_effort : ((String) -> @llm.ModelSlot)? = Some(fn(effort) {
    let rebuilt_config = config.with_reasoning_effort(effort) catch {
      err =>
        abort(
          "openai-compatible catalog effort rebuild failed: " + err.to_string(),
        )
    }
    oai_compat_catalog_slot(provider_id, rebuilt_config)
  })
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
        thinking=config.thinking,
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
  // Declared levels: `reasoning_effort` accepts an array of levels (the
  // canonical form) or a legacy single string; `reasoning_efforts` is the
  // plural alias carrying the same array. No declaration means the plain
  // off/on toggle — conventional level sets are never fabricated for an
  // endpoint that did not declare them.
  let (singular_array, singular_string) : (Array[String]?, String?) = match
    source.setting("reasoning_effort") {
    None => (None, None)
    Some(Json::Array(values)) =>
      (Some(oai_compat_effort_array_value("reasoning_effort", values)), None)
    Some(Json::String(fixed)) =>
      if fixed.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openai_compatible",
          detail="setting must not be empty: reasoning_effort",
        )
      } else {
        (None, Some(fixed))
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openai_compatible",
        detail="reasoning_effort must be an array of levels or a single string",
      )
  }
  let plural_array = oai_compat_setting_effort_array(
    source, "reasoning_efforts",
  )
  let declared_efforts : Array[String] = match (singular_array, plural_array) {
    (Some(singular), Some(plural)) =>
      if singular != plural {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openai_compatible",
          detail="reasoning_effort and reasoning_efforts declare different level lists; use one key",
        )
      } else {
        singular
      }
    (Some(singular), None) => singular
    (None, Some(plural)) => plural
    (None, None) => []
  }
  // The initial selection: an explicit legacy string wins; otherwise the
  // first declared level; an undeclared provider starts at "off".
  let config = match singular_string {
    Some(fixed) =>
      if fixed == "off" || fixed == "on" {
        if !declared_efforts.is_empty() {
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_openai_compatible",
            detail="reasoning_effort '" +
              fixed +
              "' selects the thinking toggle and cannot combine with a declared level list",
          )
        }
        OpenAICompatibleConfig::new(
          api_key,
          base_url~,
          model~,
          endpoint_prefix~,
          thinking=fixed == "on",
        )
      } else {
        if !declared_efforts.is_empty() && !declared_efforts.contains(fixed) {
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_openai_compatible",
            detail="reasoning_effort is not one of reasoning_efforts: " + fixed,
          )
        }
        OpenAICompatibleConfig::new(
          api_key,
          base_url~,
          model~,
          endpoint_prefix~,
          thinking=true,
          reasoning_effort=Some(fixed),
          thinking_efforts=if declared_efforts.is_empty() {
            [fixed]
          } else {
            declared_efforts
          },
        )
      }
    None =>
      match declared_efforts.length() {
        0 =>
          OpenAICompatibleConfig::new(
            api_key,
            base_url~,
            model~,
            endpoint_prefix~,
            thinking=false,
          )
        _ =>
          OpenAICompatibleConfig::new(
            api_key,
            base_url~,
            model~,
            endpoint_prefix~,
            thinking=true,
            reasoning_effort=Some(declared_efforts[0]),
            thinking_efforts=declared_efforts,
          )
      }
  }
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
