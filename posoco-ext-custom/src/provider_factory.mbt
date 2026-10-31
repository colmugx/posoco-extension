///|
/// provider_factory.mbt — provider-owned configuration source and catalog
/// contribution for any endpoint the user declares.
///
/// One `CustomProvider` instance is scoped to exactly one provider id (set at
/// construction). The host constructs one instance per custom settings id, the
/// same shape as a static provider extension; the host never reads a setting
/// and never decides which protocol an id speaks.

///|
pub(all) struct CustomProvider {
  provider_id : String
  ctx : @devkit.ExtContext
  /// Process-local compatibility knowledge for this one custom endpoint.
  /// Every slot built or rebuilt by this provider shares the same state.
  prompt_cache_key_rejection_state : Ref[Bool]
}

///|
pub fn CustomProvider::CustomProvider(
  provider_id : String,
  ctx~ : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> CustomProvider {
  { provider_id, ctx, prompt_cache_key_rejection_state: Ref(false), }
}

///|
fn custom_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_custom",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail="setting must be a string: " + key,
      )
  }
}

///|
/// Optional boolean setting. `None` = false; anything but a boolean is a typed
/// composition failure.
fn custom_setting_bool(
  source : @llm.ProviderConfigSource,
  key : String,
) -> Bool raise @posoco.CompositionError {
  match source.setting(key) {
    None => false
    Some(Json::True) => true
    Some(Json::False) => false
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail="setting must be a boolean: " + key,
      )
  }
}

///|
/// Parse one protocol id. Unknown values are a typed composition failure: a
/// misspelled `protocol` must never fall back to the chat wire, because the
/// fallback would answer 400 on the wrong endpoint shape.
fn custom_parse_protocol(
  origin : String,
  value : String,
) -> CustomProtocol raise @posoco.CompositionError {
  match custom_protocol_of_id(value) {
    Some(protocol) => protocol
    None =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail=origin +
          " names an unknown protocol: " +
          value +
          " (expected one of " +
          custom_protocol_choices() +
          ")",
      )
  }
}

///|
/// Provider-level `protocol`; absent means the chat-completions wire, which is
/// exactly what a settings entry written before protocols existed means.
fn custom_setting_protocol(
  source : @llm.ProviderConfigSource,
) -> CustomProtocol raise @posoco.CompositionError {
  match source.setting("protocol") {
    None => CustomProtocol::ChatCompletions
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_custom",
          detail="setting must not be empty: protocol",
        )
      } else {
        custom_parse_protocol("protocol", value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail="setting must be a string: protocol",
      )
  }
}

///|
/// Optional per-model `protocol` override (`models[]` entries only).
fn custom_entry_protocol(
  fields : Map[String, Json],
  model : String,
) -> CustomProtocol? raise @posoco.CompositionError {
  match fields.get("protocol") {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_custom",
          detail="models entry protocol must not be empty: " + model,
        )
      } else {
        Some(
          custom_parse_protocol("models entry '" + model + "' protocol", value),
        )
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail="models entry protocol must be a string: " + model,
      )
  }
}

///|
/// Credential placement. `auto` follows the protocol convention; the explicit
/// values exist for gateways that front a dialect with the other header.
fn custom_setting_auth(
  source : @llm.ProviderConfigSource,
) -> CustomAuth raise @posoco.CompositionError {
  match source.setting("auth") {
    None => CustomAuth::Auto
    Some(Json::String(value)) =>
      match custom_auth_of_id(value) {
        Some(auth) => auth
        None =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_custom",
            detail="setting auth names an unknown style: " +
              value +
              " (expected one of " +
              custom_auth_choices() +
              ")",
          )
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail="setting must be a string: auth",
      )
  }
}

///|
/// Optional positive integer setting; `None` = absent.
fn custom_setting_positive_int(
  source : @llm.ProviderConfigSource,
  key : String,
) -> Int32? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::Number(value, ..)) => {
      let parsed = value.to_int()
      if parsed.to_double() != value || parsed <= 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_custom",
          detail="setting must be a positive integer: " + key,
        )
      }
      Some(parsed)
    }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail="setting must be a positive integer: " + key,
      )
  }
}

///|
fn custom_parse_image_input(
  fields : Map[String, Json],
  model : String,
) -> Bool raise @posoco.CompositionError {
  match fields.get("image_input") {
    None => false
    Some(Json::True) => true
    Some(Json::False) => false
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail="models entry image_input must be a boolean: " + model,
      )
  }
}

///|
fn custom_effort_array_value(
  key : String,
  values : Array[Json],
) -> Array[String] raise @posoco.CompositionError {
  let efforts : Array[String] = []
  for value in values {
    match value {
      Json::String(effort) if effort.length() > 0 => efforts.push(effort)
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_custom",
          detail=key + " entries must be non-empty strings",
        )
    }
  }
  let seen : Map[String, Unit] = Map::from_array([])
  for effort in efforts {
    if effort == "off" || effort == "on" {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail=key +
          " reserves 'off'/'on' for the reasoning selector; declare explicit levels instead",
      )
    }
    if seen.contains(effort) {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail=key + " entries must be unique: " + effort,
      )
    }
    seen[effort] = ()
  }
  efforts
}

///|
fn custom_setting_effort_array(
  source : @llm.ProviderConfigSource,
  key : String,
) -> Array[String]? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::Array(values)) => Some(custom_effort_array_value(key, values))
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail=key + " must be an array of strings",
      )
  }
}

///|
fn custom_slot_efforts(config : CustomConfig) -> Array[String] {
  if config.thinking_efforts.is_empty() {
    return []
  }
  let efforts : Array[String] = ["off"]
  efforts.append(config.thinking_efforts.copy())
  efforts
}

///|
fn custom_effort_label(config : CustomConfig) -> String {
  match config.reasoning_effort {
    Some(effort) => effort
    None => "off"
  }
}

///|
/// Build one model slot. Cache policy and protocol live in `config`;
/// compatibility learning lives in the shared Ref and survives every rebuild.
fn custom_catalog_slot(
  provider_id : String,
  config : CustomConfig,
  prompt_cache_key_rejection_state : Ref[Bool],
) -> @llm.ModelSlot {
  let slot_id = provider_id + "/" + config.model
  let label = provider_id + " / " + config.model
  let slot_efforts = custom_slot_efforts(config)
  let (default_effort, rebuild_on_effort) : (
    String?,
    ((String) -> @llm.ModelSlot)?,
  ) = if slot_efforts.is_empty() {
    (None, None)
  } else {
    (
      Some(custom_effort_label(config)),
      Some(fn(effort) {
        let rebuilt_config = config.with_reasoning_effort(effort) catch {
          err =>
            abort(
              "custom provider catalog effort rebuild failed: " +
              err.to_string(),
            )
        }
        custom_catalog_slot(
          provider_id, rebuilt_config, prompt_cache_key_rejection_state,
        )
      }),
    )
  }
  let capabilities : Array[String] = ["chat", "streaming", "api_key"]
  if config.supports_images {
    capabilities.push("image_in")
  }
  let port : &@posoco.ModelPort = custom_model_port_with_prompt_cache_rejection_state(
    provider_id, config, prompt_cache_key_rejection_state,
  )
  let api_key : &@llm.ApiKeyFactory = CustomProvider(provider_id)
  @llm.ModelSlot::ModelSlot(
    id=slot_id,
    label~,
    provider_id~,
    model_id=config.model,
    port~,
    api_key=Some(api_key),
    thinking_efforts=slot_efforts,
    context_window=config.context_window,
    // Custom providers are user-autonomous settings state: the empty key opts
    // this slot out of every models.dev refresh and lookup.
    metadata_provider_id=Some(""),
    capabilities~,
    default_effort~,
    display_group=Some("custom"),
    rebuild_on_api_key=Some(fn(credential) {
      let rebuilt_config = config.with_api_key(credential.secret)
      custom_catalog_slot(
        provider_id, rebuilt_config, prompt_cache_key_rejection_state,
      )
    }),
    rebuild_on_effort~,
  )
}

///|
pub impl @llm.ProviderFactory for CustomProvider with fn provider_id(
  self : CustomProvider,
) -> String {
  self.provider_id
}

///|
pub extend CustomProvider with @llm.ProviderFactory::{
  credential_id,
  provider_id,
  build,
}

///|
pub impl @llm.ProviderFactory for CustomProvider with fn credential_id(
  self : CustomProvider,
) -> String {
  self.provider_id
}

///|
priv struct CustomModelEntry {
  model : String
  protocol : CustomProtocol?
  context_window : Int32?
  compact_threshold : Double?
  declared_efforts : Array[String]
  fixed_effort : String?
  supports_images : Bool
}

///|
fn custom_parse_models(
  values : Array[Json],
) -> Array[CustomModelEntry] raise @posoco.CompositionError {
  if values.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_custom",
      detail="models must not be empty",
    )
  }
  let entries : Array[CustomModelEntry] = []
  let seen : Map[String, Unit] = Map::from_array([])
  for value in values {
    let fields = match value {
      Json::Object(fields) => fields
      _ =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_custom",
          detail="models entries must be objects with an 'id'",
        )
    }
    let model = match fields.get("id") {
      Some(Json::String(id)) =>
        if id.length() == 0 {
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_custom",
            detail="models entry 'id' must not be empty",
          )
        } else {
          id
        }
      Some(_) =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_custom",
          detail="models entry 'id' must be a string",
        )
      None =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_custom",
          detail="models entry requires an 'id'",
        )
    }
    if seen.contains(model) {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail="models entries must have unique ids: " + model,
      )
    }
    seen[model] = ()
    let context_window = match fields.get("context_window") {
      None => None
      Some(Json::Number(value, ..)) => {
        let window = value.to_int()
        if window.to_double() != value || window <= 0 {
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_custom",
            detail="models entry context_window must be a positive integer: " +
              model,
          )
        }
        Some(window)
      }
      Some(_) =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_custom",
          detail="models entry context_window must be a positive integer",
        )
    }
    let compact_threshold = match fields.get("compact_threshold") {
      None => None
      Some(Json::Number(value, ..)) => {
        if value <= 0.0 || value > 1.0 {
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_custom",
            detail="models entry compact_threshold must be a fraction in (0, 1] (e.g. 0.85): " +
              model,
          )
        }
        if context_window is None {
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_custom",
            detail="models entry compact_threshold requires context_window: " +
              model,
          )
        }
        Some(value)
      }
      Some(_) =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_custom",
          detail="models entry compact_threshold must be a number in (0, 1]",
        )
    }
    let (singular_array, fixed_effort) : (Array[String]?, String?) = match
      fields.get("reasoning_effort") {
      None => (None, None)
      Some(Json::Array(levels)) =>
        (
          Some(custom_effort_array_value("models reasoning_effort", levels)),
          None,
        )
      Some(Json::String(fixed)) =>
        if fixed.length() == 0 {
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_custom",
            detail="models reasoning_effort must not be empty",
          )
        } else {
          (None, Some(fixed))
        }
      Some(_) =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_custom",
          detail="models reasoning_effort must be an array of levels or a single string",
        )
    }
    let plural_array : Array[String]? = match fields.get("reasoning_efforts") {
      None => None
      Some(Json::Array(levels)) =>
        Some(custom_effort_array_value("models reasoning_efforts", levels))
      Some(_) =>
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_custom",
          detail="models reasoning_efforts must be an array of strings",
        )
    }
    let declared_efforts : Array[String] = match
      (singular_array, plural_array) {
      (Some(singular), Some(plural)) =>
        if singular != plural {
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_custom",
            detail="models reasoning_effort and reasoning_efforts declare different level lists; use one key",
          )
        } else {
          singular
        }
      (Some(singular), None) => singular
      (None, Some(plural)) => plural
      (None, None) => []
    }
    entries.push({
      model,
      protocol: custom_entry_protocol(fields, model),
      context_window,
      compact_threshold,
      declared_efforts,
      fixed_effort,
      supports_images: custom_parse_image_input(fields, model),
    })
  }
  entries
}

///|
fn custom_config_from_selection(
  api_key : String,
  base_url~ : String,
  model~ : String,
  endpoint_prefix~ : String,
  protocol~ : CustomProtocol,
  auth~ : CustomAuth,
  max_output_tokens~ : Int32,
  declared_efforts~ : Array[String],
  fixed_effort~ : String? = None,
  context_window~ : Int32? = None,
  compact_threshold~ : Double? = None,
  supports_images~ : Bool = false,
  send_prompt_cache_key~ : Bool = false,
) -> CustomConfig raise @posoco.CompositionError {
  match fixed_effort {
    Some(fixed) =>
      if fixed == "off" || fixed == "on" {
        if !declared_efforts.is_empty() {
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_custom",
            detail="reasoning_effort '" +
              fixed +
              "' selects the thinking toggle and cannot combine with a declared level list",
          )
        }
        CustomConfig(
          api_key,
          base_url~,
          model~,
          endpoint_prefix~,
          protocol~,
          auth~,
          max_output_tokens~,
          context_window~,
          compact_threshold~,
          supports_images~,
          send_prompt_cache_key~,
        )
      } else {
        if !declared_efforts.is_empty() && !declared_efforts.contains(fixed) {
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_custom",
            detail="reasoning_effort is not one of reasoning_efforts: " + fixed,
          )
        }
        CustomConfig(
          api_key,
          base_url~,
          model~,
          endpoint_prefix~,
          protocol~,
          auth~,
          max_output_tokens~,
          reasoning_effort=Some(fixed),
          thinking_efforts=if declared_efforts.is_empty() {
            [fixed]
          } else {
            declared_efforts
          },
          context_window~,
          compact_threshold~,
          supports_images~,
          send_prompt_cache_key~,
        )
      }
    None =>
      match declared_efforts.length() {
        0 =>
          CustomConfig(
            api_key,
            base_url~,
            model~,
            endpoint_prefix~,
            protocol~,
            auth~,
            max_output_tokens~,
            context_window~,
            compact_threshold~,
            supports_images~,
            send_prompt_cache_key~,
          )
        _ =>
          CustomConfig(
            api_key,
            base_url~,
            model~,
            endpoint_prefix~,
            protocol~,
            auth~,
            max_output_tokens~,
            reasoning_effort=Some(declared_efforts[0]),
            thinking_efforts=declared_efforts,
            context_window~,
            compact_threshold~,
            supports_images~,
            send_prompt_cache_key~,
          )
      }
  }
}

///|
pub impl @llm.ProviderFactory for CustomProvider with fn build(
  self : CustomProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let credential = source.effective_credential(self.provider_id)
  let api_key = match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail="OAuth credential is not supported for provider " +
          self.provider_id,
      )
    Some(@oauth.ProviderCredential::ApiKey(credential)) => credential.secret
    None =>
      match custom_setting_string(source, "api_key") {
        Some(value) => value
        None => return @llm.ProviderBuildResult::Unconfigured
      }
  }
  let base_url = match custom_setting_string(source, "base_url") {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let endpoint_prefix = match custom_setting_string(source, "endpoint_prefix") {
    Some(value) => value
    None => ""
  }
  let protocol = custom_setting_protocol(source)
  let auth = custom_setting_auth(source)
  let max_output_tokens = match
    custom_setting_positive_int(source, "max_output_tokens") {
    Some(value) => value
    None => CUSTOM_DEFAULT_MAX_OUTPUT_TOKENS
  }
  let send_prompt_cache_key = custom_setting_bool(
    source, "send_prompt_cache_key",
  )
  match source.setting("models") {
    Some(Json::Array(values)) => {
      for flat_key in ["model", "reasoning_effort", "reasoning_efforts"] {
        if source.setting(flat_key) is Some(_) {
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_custom",
            detail="models cannot combine with the flat '" +
              flat_key +
              "' setting; use one style per provider",
          )
        }
      }
      let slots : Array[@llm.ModelSlot] = []
      for entry in custom_parse_models(values) {
        let config = custom_config_from_selection(
          api_key,
          base_url~,
          model=entry.model,
          endpoint_prefix~,
          protocol=entry.protocol.unwrap_or(protocol),
          auth~,
          max_output_tokens~,
          declared_efforts=entry.declared_efforts,
          fixed_effort=entry.fixed_effort,
          context_window=entry.context_window,
          compact_threshold=entry.compact_threshold,
          supports_images=entry.supports_images,
          send_prompt_cache_key~,
        )
        slots.push(
          custom_catalog_slot(
            self.provider_id,
            config,
            self.prompt_cache_key_rejection_state,
          ),
        )
      }
      @llm.ProviderBuildResult::Ready(
        @llm.ProviderModelCatalog::ProviderModelCatalog(
          provider_id=self.provider_id,
          slots~,
          capabilities=["chat", "streaming", "api_key"],
        ),
      )
    }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_custom",
        detail="models must be an array of {id, protocol?, context_window?, compact_threshold?, reasoning_effort?} entries",
      )
    None => {
      let model = match custom_setting_string(source, "model") {
        Some(value) => value
        None => return @llm.ProviderBuildResult::Unconfigured
      }
      let (singular_array, singular_string) : (Array[String]?, String?) = match
        source.setting("reasoning_effort") {
        None => (None, None)
        Some(Json::Array(values)) =>
          (Some(custom_effort_array_value("reasoning_effort", values)), None)
        Some(Json::String(fixed)) =>
          if fixed.length() == 0 {
            raise @posoco.CompositionError::ManifestSchemaError(
              manifest_id="posoco_ext_custom",
              detail="setting must not be empty: reasoning_effort",
            )
          } else {
            (None, Some(fixed))
          }
        Some(_) =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_custom",
            detail="reasoning_effort must be an array of levels or a single string",
          )
      }
      let plural_array = custom_setting_effort_array(
        source, "reasoning_efforts",
      )
      let declared_efforts : Array[String] = match
        (singular_array, plural_array) {
        (Some(singular), Some(plural)) =>
          if singular != plural {
            raise @posoco.CompositionError::ManifestSchemaError(
              manifest_id="posoco_ext_custom",
              detail="reasoning_effort and reasoning_efforts declare different level lists; use one key",
            )
          } else {
            singular
          }
        (Some(singular), None) => singular
        (None, Some(plural)) => plural
        (None, None) => []
      }
      let config = custom_config_from_selection(
        api_key,
        base_url~,
        model~,
        endpoint_prefix~,
        protocol~,
        auth~,
        max_output_tokens~,
        declared_efforts~,
        fixed_effort=singular_string,
        supports_images=custom_setting_bool(source, "image_input"),
        send_prompt_cache_key~,
      )
      @llm.ProviderBuildResult::Ready(
        @llm.ProviderModelCatalog::ProviderModelCatalog(
          provider_id=self.provider_id,
          slots=[
            custom_catalog_slot(
              self.provider_id,
              config,
              self.prompt_cache_key_rejection_state,
            ),
          ],
          capabilities=["chat", "streaming", "api_key"],
        ),
      )
    }
  }
}

///|
pub fn CustomModelPort::model_catalog(
  self : CustomModelPort,
) -> @llm.ProviderModelCatalog raise @posoco.CompositionError {
  ignore(self.prompt_cache_key_rejected_now())
  @llm.ProviderModelCatalog::ProviderModelCatalog(
    provider_id=self.provider_id,
    slots=[
      custom_catalog_slot(
        self.provider_id,
        self.config,
        self.prompt_cache_key_rejection_state,
      ),
    ],
    capabilities=["chat", "streaming", "api_key"],
  )
}

///|
pub impl @llm.ApiKeyFactory for CustomProvider with fn provider_id(
  self : CustomProvider,
) -> String {
  self.provider_id
}

///|
pub extend CustomProvider with @llm.ApiKeyFactory::{login}

///|
pub impl @llm.ApiKeyFactory for CustomProvider with fn credential_id(
  self : CustomProvider,
) -> String {
  self.provider_id
}

///|
pub impl @llm.ApiKeyFactory for CustomProvider with fn login(
  self : CustomProvider,
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
