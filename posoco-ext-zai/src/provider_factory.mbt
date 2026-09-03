///|
pub(all) struct ZaiProvider {
  ctx : @devkit.ExtContext
}

///|
pub fn ZaiProvider::ZaiProvider(
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> ZaiProvider {
  { ctx, }
}

///|
fn zai_setting_string(
  source : @llm.ProviderConfigSource,
  key : String,
) -> String? raise @posoco.CompositionError {
  match source.setting(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_zai",
          detail="setting must not be empty: " + key,
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_zai",
        detail="setting must be a string: " + key,
      )
  }
}

///|
/// Split a custom base_url into (host, path_prefix); a bare host gets the
/// platform's default prefix.
pub fn zai_endpoint_parts(
  url : String,
  default_prefix : String,
) -> (String, String) {
  match url.find("://") {
    None => (url, default_prefix)
    Some(protocol_end) => {
      let after_start = protocol_end + 3
      let after = url.sub(start=after_start)
      match after.find("/") {
        None => (url, default_prefix)
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
/// Resolve (base_url, endpoint_prefix) from the platform choice and the
/// optional `base_url` override; a custom url with no path keeps the
/// platform's default prefix.
fn zai_resolve_endpoint(
  source : @llm.ProviderConfigSource,
  platform : String,
) -> (String, String) raise @posoco.CompositionError {
  let (default_base, default_prefix) = match zai_platform_endpoint(platform) {
    Some(parts) => parts
    None =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_zai",
        detail="unknown platform: " + platform + " (expected bigmodel | zai)",
      )
  }
  match zai_setting_string(source, "base_url") {
    Some(url) => zai_endpoint_parts(url, default_prefix)
    None => (default_base, default_prefix)
  }
}

///|
/// The platform a credential was minted for, as recorded by the `/login`
/// platform picker. Credentials without the marker (hand-written files,
/// legacy records) resolve through settings instead.
fn zai_credential_platform(credential : @oauth.ApiKeyCredential) -> String? {
  match credential.metadata.get("platform") {
    Some(value) => Some(value)
    None => None
  }
}

///|
/// Endpoint preset recorded by a credential's platform choice; `None` when
/// the credential carries no known platform marker.
fn zai_credential_endpoint(
  credential : @oauth.ApiKeyCredential,
) -> (String, String)? {
  match zai_credential_platform(credential) {
    Some(value) => zai_platform_endpoint(value)
    None => None
  }
}

///|
pub impl @llm.ProviderFactory for ZaiProvider with fn provider_id(
  _self : ZaiProvider,
) -> String {
  "zai"
}

///|
pub impl @llm.ProviderFactory for ZaiProvider with fn credential_id(
  _self : ZaiProvider,
) -> String {
  "zai"
}

///|
/// Catalog identity for the direct-API provider: the credential's platform
/// marker remaps the endpoint on slot rebuilds.
fn zai_catalog_identity() -> ZaiCatalogIdentity {
  ZaiCatalogIdentity::ZaiCatalogIdentity(
    provider_id="zai",
    label_prefix="Z.ai",
    manifest_id="posoco_ext_zai",
    endpoint_for_credential=Some(zai_credential_endpoint),
  )
}

///|
/// Direct platform API access: keys are created in the Z.ai or BigModel
/// console and travel as `Authorization: Bearer`. An OAuth credential is a
/// typed composition failure, not a silent downgrade. The platform endpoint
/// comes from the credential's recorded login choice, with the `platform`
/// setting as the settings-only fallback and Z.ai as the default.
pub impl @llm.ProviderFactory for ZaiProvider with fn build(
  self : ZaiProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  match zai_build_config(source) {
    Some(config) => {
      let api_key_impl = ZaiProvider(ctx=self.ctx)
      let api_key : &@llm.ApiKeyFactory = api_key_impl
      // Host-cached ids from a previous refresh expand into the discovered
      // catalog offline; without them the preset catalog stands until an
      // explicit refresh. Bad records degrade, never fail.
      let catalog = match parse_cached_zai_models(source.cached_models) {
        Some(ids) =>
          zai_model_catalog_from_ids(
            ids,
            config,
            self.ctx,
            zai_catalog_identity(),
            api_key,
          )
        None =>
          zai_model_catalog(config, self.ctx, zai_catalog_identity(), api_key)
      }
      @llm.ProviderBuildResult::Ready(catalog)
    }
    None => @llm.ProviderBuildResult::Unconfigured
  }
}

///|
/// Effective direct-API config from settings + credential; `None` when no
/// API key is present anywhere. The credential's recorded platform wins over
/// the `platform` setting, which wins over the Z.ai default.
fn zai_build_config(
  source : @llm.ProviderConfigSource,
) -> ZaiConfig? raise @posoco.CompositionError {
  let credential = source.effective_credential("zai")
  let mut credential_platform : String? = None
  let api_key = match credential {
    Some(@oauth.ProviderCredential::OAuth(_)) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_zai",
        detail="z.ai has no OAuth; use an API key from z.ai/model-api",
      )
    Some(@oauth.ProviderCredential::ApiKey(credential)) => {
      credential_platform = zai_credential_platform(credential)
      credential.secret
    }
    None =>
      match zai_setting_string(source, "api_key") {
        Some(value) => value
        None => return None
      }
  }
  let platform = match credential_platform {
    Some(value) => value
    None =>
      match zai_setting_string(source, "platform") {
        Some(value) => value
        None => "zai"
      }
  }
  let model = match zai_setting_string(source, "model") {
    Some(value) => value
    None => "glm-5.3"
  }
  let (base_url, endpoint_prefix) = zai_resolve_endpoint(source, platform)
  let config = ZaiConfig::for_model(api_key, model, base_url~, endpoint_prefix~)
  let requested_effort = zai_setting_string(source, "reasoning_effort")
  match requested_effort {
    None => Some(config)
    Some(effort) => Some(config.with_reasoning_effort(effort))
  }
}

///|
pub impl @llm.ApiKeyFactory for ZaiProvider with fn provider_id(
  _self : ZaiProvider,
) -> String {
  "zai"
}

///|
pub impl @llm.ApiKeyFactory for ZaiProvider with fn credential_id(
  _self : ZaiProvider,
) -> String {
  "zai"
}

///|
/// Two-step login: first pick the platform to connect to (BigModel China or
/// Z.ai international), then supply that platform's API key. The choice is
/// recorded in the credential metadata so `build` and slot rebuilds land on
/// the matching endpoint without extra settings.
pub impl @llm.ApiKeyFactory for ZaiProvider with fn login(
  _self : ZaiProvider,
  interaction : &@oauth.AuthPromptInteraction,
) -> @oauth.ApiKeyCredential raise @oauth.OAuthError {
  let platform = interaction.prompt(
    @oauth.AuthPromptRequest::Select(message="Connect to bigmodel or Z.ai?", options=[
      @oauth.AuthPromptOption::AuthPromptOption(
        id="zai",
        label="Z.ai (api.z.ai)",
        description=Some("Z.ai international platform, pay-as-you-go balance"),
      ),
      @oauth.AuthPromptOption::AuthPromptOption(
        id="bigmodel",
        label="bigmodel (open.bigmodel.cn)",
        description=Some("Zhipu BigModel China platform, pay-as-you-go balance"),
      ),
    ]),
  )
  if zai_platform_endpoint(platform) is None {
    raise @oauth.OAuthError::ParseError("unknown platform choice: " + platform)
  }
  let secret = interaction.prompt(
    @oauth.AuthPromptRequest::Secret(message="Z.ai API key for " + platform),
  )
  if secret.length() == 0 {
    raise @oauth.OAuthError::ParseError("Z.ai API key must not be empty")
  }
  @oauth.ApiKeyCredential::ApiKeyCredential(
    secret~,
    metadata=Map::from_array([("platform", platform)]),
  )
}

///|
pub impl @llm.RefreshableProviderFactory for ZaiProvider with fn provider_id(
  _self : ZaiProvider,
) -> String {
  "zai"
}

///|
/// Explicit live model discovery: exactly one authenticated `/models` request
/// against the resolved platform endpoint. Unlike `build`, this path fails
/// composition on transport or schema errors; it never falls back to the
/// preset catalog.
pub impl @llm.RefreshableProviderFactory for ZaiProvider with fn refresh(
  self : ZaiProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  match zai_build_config(source) {
    Some(config) => {
      let ids = fetch_zai_models(
        config.base_url,
        config.api_key,
        endpoint_prefix=config.endpoint_prefix,
      ) catch {
        err =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_zai",
            detail="zai model catalog refresh failed: " + err.to_string(),
          )
      }
      let api_key_impl = ZaiProvider(ctx=self.ctx)
      let api_key : &@llm.ApiKeyFactory = api_key_impl
      @llm.ProviderBuildResult::Ready(
        zai_model_catalog_from_ids(
          ids,
          config,
          self.ctx,
          zai_catalog_identity(),
          api_key,
        ),
      )
    }
    None => @llm.ProviderBuildResult::Unconfigured
  }
}
