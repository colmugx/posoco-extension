///|
/// Native+wasm+js: moonbitlang/async/http (`@http`) is unavailable on wasm-gc.

///|
/// Live refresh: `/models`, models.dev enrichment (best-effort), grant renewal
/// when close to expiry, and re-registration of the `/usage` quota source.
#cfg(any(target="native", target="wasm", target="js"))
pub impl @llm.RefreshableProviderFactory for OpenCodeGoProvider with fn refresh(
  self : OpenCodeGoProvider,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  let mut auth = match go_resolve_auth(source) {
    Some(value) => value
    None => return @llm.ProviderBuildResult::Unconfigured
  }
  if auth.oauth {
    match source.effective_credential(go_provider_id) {
      Some(@oauth.ProviderCredential::OAuth(stored)) =>
        match go_oauth_session(stored) {
          Some(session) if go_oauth_is_expiring(session, go_now_secs()) => {
            let renewed = go_oauth_refresh(stored) catch {
              err =>
                raise @posoco.CompositionError::ManifestSchemaError(
                  manifest_id="posoco_ext_opencode_go",
                  detail="OpenCode Go account login could not be renewed (" +
                    go_oauth_error_text(err) +
                    "); run /login opencode-go",
                )
            }
            // The refresh token rotated; persist before requesting. A store
            // failure keeps the renewed token in memory for this build.
            match source.credential_store {
              Some(store) =>
                store.write(
                  go_provider_id,
                  @oauth.ProviderCredential::OAuth(renewed),
                ) catch {
                  _ => ()
                }
              None => ()
            }
            let renewed_session = go_oauth_session(renewed)
            auth = {
              ..auth,
              api_key: renewed.access_token,
              org_id: match renewed_session {
                Some(value) => value.org_id
                None => auth.org_id
              },
            }
          }
          _ => ()
        }
      _ => ()
    }
  }
  let base_url = go_resolve_base_url(source, auth)
  let preferred = go_resolve_model(source)
  let overrides = go_protocol_overrides(source)
  let policy = go_deepseek_policy(source)
  let extra_headers = go_extra_headers(auth.org_id)
  let config = @zen.OpenCodeZenConfig(
    auth.api_key,
    base_url~,
    model=preferred,
    client_id="opencode-go",
    spend_source="posoco_ext_opencode_go",
    extra_headers~,
    bearer_auth=auth.oauth,
  )
  let models = @zen.fetch_zen_models(
    config.base_url,
    config.api_key,
    extra_headers~,
  ) catch {
    err =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_opencode_go",
        detail="OpenCode Go model catalog refresh failed: " + err.to_string(),
      )
  }
  // Deliberate degradation: a missing models.dev mirror must not fail the
  // whole refresh — the picker falls back to off/on per model, windows stay
  // undeclared, and the wire re-derives from the Go-plane table.
  let metas : Map[String, @zen.ZenModelMeta] = @zen.fetch_models_dev_meta() catch {
    _ => Map::from_array([])
  }
  let api_key_factory : &@llm.ApiKeyFactory = self
  let catalog = go_model_catalog(
    config,
    models,
    preferred,
    metas,
    api_key_factory,
    overrides~,
    policy=Some(policy),
    ctx=self.ctx,
  )
  go_register_quota_source(base_url, auth.api_key, extra_headers~)
  @llm.ProviderBuildResult::Ready(catalog)
}

///|
pub extend OpenCodeGoProvider with @posoco/ext-llm.RefreshableProviderFactory::{
  refresh,
}
