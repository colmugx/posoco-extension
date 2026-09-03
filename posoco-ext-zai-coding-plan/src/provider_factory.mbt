///|
/// GLM Coding Plan endpoint presets. The plan only honors plan quota on the
/// coding endpoints; direct platform API access (pay-as-you-go balance)
/// lives in posoco-ext-zai.
pub fn zai_coding_plan_profile_endpoint(profile : String) -> (String, String)? {
  match profile {
    "coding" => Some(("https://api.z.ai", "/api/coding/paas/v4"))
    "cn_coding" => Some(("https://open.bigmodel.cn", "/api/coding/paas/v4"))
    _ => None
  }
}

///|
pub(all) struct ZaiCodingPlanProvider {
  ctx : @devkit.ExtContext
}

///|
pub fn ZaiCodingPlanProvider::ZaiCodingPlanProvider(
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> ZaiCodingPlanProvider {
  { ctx, }
}

///|
fn zai_coding_plan_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_zai_coding_plan",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_zai_coding_plan",
        detail="setting must be a string: " + key,
      )
  }
}

///|
/// Resolve (base_url, endpoint_prefix) from the profile and the optional
/// `base_url` override; a custom url with no path keeps the profile prefix.
fn zai_coding_plan_resolve_endpoint(
  source : @llm.ProviderConfigSource,
  profile : String,
) -> (String, String) raise @posoco.CompositionError {
  let (default_base, default_prefix) = match
    zai_coding_plan_profile_endpoint(profile) {
    Some(parts) => parts
    None =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_zai_coding_plan",
        detail="unknown profile: " + profile + " (expected coding | cn_coding)",
      )
  }
  match zai_coding_plan_setting_string(source, "base_url") {
    Some(url) => @zai.zai_endpoint_parts(url, default_prefix)
    None => (default_base, default_prefix)
  }
}

///|
pub impl @llm.ProviderFactory for ZaiCodingPlanProvider with fn provider_id(
  _self : ZaiCodingPlanProvider,
) -> String {
  "zai-coding-plan"
}

///|
pub impl @llm.ProviderFactory for ZaiCodingPlanProvider with fn credential_id(
  _self : ZaiCodingPlanProvider,
) -> String {
  "zai-coding-plan"
}

///|
/// The Coding Plan has no OAuth — plan keys are created in the coding-plan
/// console and travel as `Authorization: Bearer`. An OAuth credential is a
/// typed composition failure, not a silent downgrade.
pub impl @llm.ProviderFactory for ZaiCodingPlanProvider with fn build(
  self : ZaiCodingPlanProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  match zai_coding_plan_build_config(source) {
    Some(config) => {
      let identity = @zai.ZaiCatalogIdentity::ZaiCatalogIdentity(
        provider_id="zai-coding-plan",
        label_prefix="Z.ai Coding Plan",
        manifest_id="posoco_ext_zai_coding_plan",
        endpoint_for_credential=None,
      )
      let api_key_impl = ZaiCodingPlanProvider(ctx=self.ctx)
      let api_key : &@llm.ApiKeyFactory = api_key_impl
      @llm.ProviderBuildResult::Ready(
        @zai.zai_model_catalog(config, self.ctx, identity, api_key, capabilities=[
          "chat", "streaming", "api_key", "coding_plan",
        ]),
      )
    }
    None => @llm.ProviderBuildResult::Unconfigured
  }
}

///|
/// Effective coding-plan config from settings + credential; `None` when no
/// API key is present anywhere.
fn zai_coding_plan_build_config(
  source : @llm.ProviderConfigSource,
) -> @zai.ZaiConfig? raise @posoco.CompositionError {
  let api_key = match zai_coding_plan_api_key(source) {
    Some(value) => value
    None => return None
  }
  let model = match zai_coding_plan_setting_string(source, "model") {
    Some(value) => value
    None => "glm-5.3"
  }
  let profile = match zai_coding_plan_setting_string(source, "profile") {
    Some(value) => value
    None => "coding"
  }
  let (base_url, endpoint_prefix) = zai_coding_plan_resolve_endpoint(
    source, profile,
  )
  let config = @zai.ZaiConfig::for_model(
    api_key,
    model,
    base_url~,
    endpoint_prefix~,
  )
  let requested_effort = zai_coding_plan_setting_string(
    source, "reasoning_effort",
  )
  match requested_effort {
    None => Some(config)
    Some(effort) =>
      Some(
        config.with_reasoning_effort(
          effort,
          manifest_id="posoco_ext_zai_coding_plan",
        ),
      )
  }
}

///|
/// Plan API key from settings + credential; `None` when no key is present
/// anywhere. Shared by the model catalog and the quota probe so both read
/// the account through one credential.
fn zai_coding_plan_api_key(
  source : @llm.ProviderConfigSource,
) -> String? raise @posoco.CompositionError {
  let credential = source.effective_credential("zai-coding-plan")
  match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_zai_coding_plan",
        detail="the GLM Coding Plan has no OAuth; use a coding-plan API key",
      )
    Some(@oauth.ProviderCredential::ApiKey(credential)) =>
      Some(credential.secret)
    None => zai_coding_plan_setting_string(source, "api_key")
  }
}

///|
/// A quota probe wired from the same settings + credential the model catalog
/// uses; `None` when the provider is unconfigured. The monitor endpoint
/// lives on the profile's platform domain, not under the chat prefix.
pub fn ZaiCodingPlanProvider::quota_source(
  _self : ZaiCodingPlanProvider,
  source : @llm.ProviderConfigSource,
) -> ZaiCodingPlanQuotaSource? raise @posoco.CompositionError {
  let api_key = match zai_coding_plan_api_key(source) {
    Some(value) => value
    None => return None
  }
  let profile = match zai_coding_plan_setting_string(source, "profile") {
    Some(value) => value
    None => "coding"
  }
  let (base_url, _endpoint_prefix) = zai_coding_plan_resolve_endpoint(
    source, profile,
  )
  Some(ZaiCodingPlanQuotaSource(api_key~, base_url~))
}

///|
pub impl @llm.ApiKeyFactory for ZaiCodingPlanProvider with fn provider_id(
  _self : ZaiCodingPlanProvider,
) -> String {
  "zai-coding-plan"
}

///|
pub impl @llm.ApiKeyFactory for ZaiCodingPlanProvider with fn credential_id(
  _self : ZaiCodingPlanProvider,
) -> String {
  "zai-coding-plan"
}

///|
/// Plan keys come from the coding-plan console; the platform endpoint is
/// chosen through the `profile` setting, so login only collects the key.
pub impl @llm.ApiKeyFactory for ZaiCodingPlanProvider with fn login(
  _self : ZaiCodingPlanProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="GLM Coding Plan API key"),
  )
  if secret.length() == 0 {
    raise @oauth.OAuthError::ParseError(
      "GLM Coding Plan API key must not be empty",
    )
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(secret~)
}
