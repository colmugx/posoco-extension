///| 
/// Provider-owned configuration source and catalog contribution.

///|
pub(all) struct DeepSeekProvider {
  ctx : @devkit.ExtContext
}

///|
pub fn DeepSeekProvider::DeepSeekProvider(
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> DeepSeekProvider {
  { ctx, }
}

///|
fn deepseek_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_deepseek",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="setting must be a string: " + key,
      )
  }
}

///|
/// Keep URL parsing in the provider extension. The host passes one opaque
/// base_url string; DeepSeek decides how its path prefix maps to chat/FIM.
fn deepseek_endpoint_parts(url : String) -> (String, String) {
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
pub impl @llm.ProviderFactory for DeepSeekProvider with fn provider_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
pub impl @llm.ProviderFactory for DeepSeekProvider with fn credential_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
/// DeepSeek API key from settings + credential; `None` when no key is present
/// anywhere. Shared by the catalog build/refresh and the balance probe so
/// both read the account through one credential.
fn deepseek_api_key(
  source : @llm.ProviderConfigSource,
) -> String? raise @posoco.CompositionError {
  let credential = source.effective_credential("deepseek")
  match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="OAuth credential is not supported for provider deepseek",
      )
    Some(@oauth.ProviderCredential::ApiKey(value)) => Some(value.secret)
    None => deepseek_setting_string(source, "api_key")
  }
}

///|
/// A balance probe wired from the same settings + credential the model
/// catalog uses; `None` when the provider is unconfigured. The balance
/// endpoint lives on the platform root, not under the chat prefix.
pub fn DeepSeekProvider::balance_source(
  _self : DeepSeekProvider,
  source : @llm.ProviderConfigSource,
) -> DeepSeekBalanceSource? raise @posoco.CompositionError {
  let api_key = match deepseek_api_key(source) {
    Some(value) => value
    None => return None
  }
  let base_setting = match deepseek_setting_string(source, "base_url") {
    Some(value) => value
    None => "https://api.deepseek.com"
  }
  let (base_url, _endpoint_prefix) = deepseek_endpoint_parts(base_setting)
  Some(DeepSeekBalanceSource(api_key~, base_url~))
}

///|
/// Settings-level effort gate shared by build and refresh: the empty string
/// (thinking disabled) plus every provider-wide selectable effort.
fn deepseek_setting_effort_supported(effort : String) -> Bool {
  effort == "" || deepseek_reasoning_efforts().contains(effort)
}

///|
pub impl @llm.ProviderFactory for DeepSeekProvider with fn build(
  self : DeepSeekProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let api_key = match deepseek_api_key(source) {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let model = match deepseek_setting_string(source, "model") {
    Some(value) => value
    None => "deepseek-v4-flash"
  }
  let base_url_setting = match deepseek_setting_string(source, "base_url") {
    Some(value) => value
    None => "https://api.deepseek.com"
  }
  let (base_url, endpoint_prefix) = deepseek_endpoint_parts(base_url_setting)
  let effort = match deepseek_setting_string(source, "reasoning_effort") {
    Some("off") => ""
    Some(value) => value
    None => "high"
  }
  if !deepseek_setting_effort_supported(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_deepseek",
      detail="unsupported reasoning_effort: " + effort,
    )
  }
  let config = DeepSeekConfig(
    api_key,
    model~,
    base_url~,
    endpoint_prefix~,
    reasoning_effort=effort,
  )
  let port = DeepSeekModelPort(config, ctx=self.ctx)
  // Host-cached records from a previous refresh expand into the full
  // multi-slot catalog offline; without them the static single-model catalog
  // stands until an explicit refresh. Bad records degrade, never fail.
  let catalog = match parse_cached_deepseek_models(source.cached_models) {
    Some(models) => port.model_catalog_from_models(models)
    None => port.model_catalog()
  }
  // Pull-style quota: publish the balance probe under the provider id so the
  // /status command reads it live at command time. Every configured build
  // re-registers, so the registry holds the latest credential snapshot.
  match self.balance_source(source) {
    Some(src) => {
      let borrowed : &@devkit.QuotaSource = src
      @devkit.quota_registry_register("deepseek", borrowed)
    }
    None => ()
  }
  // Pull-style pricing: publish the vendor peak/off-peak rule next to the
  // quota source so the /model catalog reads it live at command time. The
  // rule is static clock fact, so every configured build re-registers it
  // without needing a credential snapshot.
  let pricing_borrowed : &@devkit.PricingSource = DeepSeekPricingSource::{ }
  @devkit.pricing_registry_register("deepseek", pricing_borrowed)
  @llm.ProviderBuildResult::Ready(catalog)
}

///|
pub impl @llm.RefreshableProviderFactory for DeepSeekProvider with fn provider_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
/// Explicit live model discovery. Unlike `build`, this path performs exactly
/// one authenticated `/models` request and fails composition on transport or
/// schema errors; it never falls back to the configured static model.
pub impl @llm.RefreshableProviderFactory for DeepSeekProvider with fn refresh(
  self : DeepSeekProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let api_key = match deepseek_api_key(source) {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  let model = match deepseek_setting_string(source, "model") {
    Some(value) => value
    None => "deepseek-v4-flash"
  }
  let base_setting = match deepseek_setting_string(source, "base_url") {
    Some(value) => value
    None => "https://api.deepseek.com"
  }
  let (base_url, endpoint_prefix) = deepseek_endpoint_parts(base_setting)
  let requested_effort = match
    deepseek_setting_string(source, "reasoning_effort") {
    Some("off") => ""
    Some(value) => value
    None => "high"
  }
  // Keep live refresh validation identical to the static build path.  In
  // particular, an unknown configured effort is a typed composition failure,
  // not the abort emitted by DeepSeekConfig for an invalid value.
  if !deepseek_setting_effort_supported(requested_effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_deepseek",
      detail="unsupported reasoning_effort: " + requested_effort,
    )
  }
  let config = DeepSeekConfig(
    api_key,
    model~,
    base_url~,
    endpoint_prefix~,
    reasoning_effort=requested_effort,
  )
  let models = fetch_deepseek_models(
    config.base_url,
    config.api_key,
    endpoint_prefix=config.endpoint_prefix,
  ) catch {
    err =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_deepseek",
        detail="DeepSeek model catalog refresh failed: " + err.to_string(),
      )
  }
  let port = DeepSeekModelPort(config, ctx=self.ctx)
  // Same registry publication as build: refresh carries the newest
  // credentials, so the /status pull source follows it.
  match self.balance_source(source) {
    Some(src) => {
      let borrowed : &@devkit.QuotaSource = src
      @devkit.quota_registry_register("deepseek", borrowed)
    }
    None => ()
  }
  // Same registry publication as build: the static pricing rule follows the
  // newest refresh so the /model catalog pull stays live.
  let pricing_borrowed : &@devkit.PricingSource = DeepSeekPricingSource::{ }
  @devkit.pricing_registry_register("deepseek", pricing_borrowed)
  @llm.ProviderBuildResult::Ready(port.model_catalog_from_models(models))
}

///|
/// Provider-owned API-key login. The host supplies only a provider-neutral
/// secret prompt; validation and credential shape stay in this extension.
pub impl @llm.ApiKeyFactory for DeepSeekProvider with fn provider_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
pub impl @llm.ApiKeyFactory for DeepSeekProvider with fn credential_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
pub impl @llm.ApiKeyFactory for DeepSeekProvider with fn login(
  _self : DeepSeekProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="DeepSeek API key"),
  )
  if secret.length() == 0 {
    raise @oauth.OAuthError::ParseError("DeepSeek API key must not be empty")
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}
