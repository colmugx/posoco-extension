///| 
/// Provider-owned configuration source and catalog contribution.

///|
pub(all) struct DeepSeekProvider {
  ctx : @devkit.ExtContext
}

///|
pub fn DeepSeekProvider::DeepSeekProvider(
  ctx~ : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> DeepSeekProvider {
  { ctx, }
}

///|
pub impl @provider.ProviderFactory for DeepSeekProvider with fn provider_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
pub extend DeepSeekProvider with @provider.ProviderFactory::{
  credential_id,
  provider_id,
  build,
}

///|
pub impl @provider.ProviderFactory for DeepSeekProvider with fn credential_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
/// A balance probe wired from the same settings + credential the model
/// catalog uses; `None` when the provider is unconfigured. The balance
/// endpoint lives on the platform root, not under the chat prefix.
pub fn DeepSeekProvider::balance_source(
  _self : DeepSeekProvider,
  source : @provider.ProviderConfigSource,
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
/// Pull-style registry publication shared by build and refresh: the quota
/// probe under the provider id so the /status command reads it live at
/// command time, plus the static vendor peak/off-peak pricing rule next to
/// it. Every configured build/refresh re-registers, so the registry holds
/// the latest credential snapshot; the pricing rule needs no credential.
fn DeepSeekProvider::publish_quota_and_pricing(
  self : DeepSeekProvider,
  source : @provider.ProviderConfigSource,
) -> Unit raise @posoco.CompositionError {
  match self.balance_source(source) {
    Some(src) => {
      let borrowed : &@devkit.QuotaSource = src
      @devkit.quota_registry_register("deepseek", borrowed)
    }
    None => ()
  }
  let pricing_borrowed : &@devkit.PricingSource = DeepSeekPricingSource::{ }
  @devkit.pricing_registry_register("deepseek", pricing_borrowed)
}

///|
pub impl @provider.ProviderFactory for DeepSeekProvider with fn build(
  self : DeepSeekProvider,
  source : @provider.ProviderConfigSource,
) -> @provider.ProviderBuildResult raise @posoco.CompositionError {
  let config = match deepseek_provider_config(source) {
    Some(config) => config
    None => return @provider.ProviderBuildResult::Unconfigured
  }
  let port = DeepSeekModelPort(config, ctx=self.ctx)
  // Host-cached records from a previous refresh expand into the full
  // multi-slot catalog offline; without them the static single-model catalog
  // stands until an explicit refresh. Bad records degrade, never fail.
  let catalog = match parse_cached_deepseek_models(source.cached_models) {
    Some(models) => port.model_catalog_from_models(models)
    None => port.model_catalog()
  }
  self.publish_quota_and_pricing(source)
  @provider.ProviderBuildResult::Ready(
    catalog.with_cached_context_windows(source.cached_models),
  )
}

///|
pub impl @provider.RefreshableProviderFactory for DeepSeekProvider with fn provider_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
/// Explicit live model discovery. Unlike `build`, this path performs exactly
/// one authenticated `/models` request and fails composition on transport or
/// schema errors; it never falls back to the configured static model.
pub impl @provider.RefreshableProviderFactory for DeepSeekProvider with fn refresh(
  self : DeepSeekProvider,
  source : @provider.ProviderConfigSource,
) -> @provider.ProviderBuildResult raise @posoco.CompositionError {
  let config = match deepseek_provider_config(source) {
    Some(config) => config
    None => return @provider.ProviderBuildResult::Unconfigured
  }
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
  self.publish_quota_and_pricing(source)
  @provider.ProviderBuildResult::Ready(port.model_catalog_from_models(models))
}

///|
/// Provider-owned API-key login. The host supplies only a provider-neutral
/// secret prompt; validation and credential shape stay in this extension.
pub impl @provider.ApiKeyFactory for DeepSeekProvider with fn provider_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
pub extend DeepSeekProvider with @provider.ApiKeyFactory::{login}

///|
pub impl @provider.ApiKeyFactory for DeepSeekProvider with fn credential_id(
  _self : DeepSeekProvider,
) -> String {
  "deepseek"
}

///|
pub impl @provider.ApiKeyFactory for DeepSeekProvider with fn login(
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
