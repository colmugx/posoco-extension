///|
/// Load-time credential renewal for the Codex OAuth catalog refresh. The
/// stored access token renews through the OAuth refresh grant when expired or
/// rejected (HTTP 401), and the rotated record persists back through the
/// snapshot's credential store. Only a rejected refresh token surfaces as a
/// composition error; every other failure keeps the catalog-refresh error
/// shape hosts already render.

///|
fn openai_now_epoch_secs() -> Int {
  (@async.now() / 1000L).to_int()
}

///|
fn codex_account_id_of(
  credential : @oauth.Credential,
) -> String raise @posoco.CompositionError {
  match credential.metadata_value("account_id") {
    Some(value) if value.length() > 0 => value
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_openai",
        detail="Codex model refresh requires account_id credential metadata",
      )
  }
}

///|
/// Stable renewal-failure text. OAuthError's Show lives in ext-oauth, so the
/// renewal path renders its own variant summary to keep detail strings local
/// and testable.
fn oauth_refresh_error_text(err : @oauth.OAuthError) -> String {
  match err {
    @oauth.OAuthError::AuthPending => "auth_pending"
    @oauth.OAuthError::SlowDown => "slow_down"
    @oauth.OAuthError::AccessDenied => "access_denied"
    @oauth.OAuthError::ExpiredToken => "expired_token"
    @oauth.OAuthError::InvalidGrant => "invalid_grant"
    @oauth.OAuthError::HttpError(detail) => "http_error(" + detail + ")"
    @oauth.OAuthError::ParseError(detail) => "parse_error(" + detail + ")"
    @oauth.OAuthError::Cancelled => "cancelled"
  }
}

///|
fn codex_renewal_failed_error(
  err : @oauth.OAuthError,
) -> @posoco.CompositionError {
  let detail = match err {
    @oauth.OAuthError::InvalidGrant =>
      "Codex refresh_token rejected (invalid_grant); browser re-login required"
    other => "Codex token renewal failed: " + oauth_refresh_error_text(other)
  }
  @posoco.CompositionError::ManifestSchemaError(
    manifest_id="posoco_ext_openai",
    detail~,
  )
}

///|
fn codex_models_refresh_failed_error(err : Error) -> @posoco.CompositionError {
  let text = match err {
    ModelsFetchError::HttpStatus(status~, body_chars~) =>
      HttpStatus(status~, body_chars~).to_model_error().to_string()
    ModelsFetchError::Upstream(inner) => inner.to_string()
    other => other.to_string()
  }
  @posoco.CompositionError::ManifestSchemaError(
    manifest_id="posoco_ext_openai",
    detail="Codex model catalog refresh failed: " + text,
  )
}

///|
/// Renew the Codex credential and persist the rotated record best-effort.
/// The renewed credential returns even when the store write fails: a working
/// access token must not be discarded on a persistence hiccup, and the next
/// refresh retries the write from the still-stale disk record.
async fn renew_codex_credential(
  oauth_transport : &@oauth.OAuthHttpTransport?,
  credential : @oauth.Credential,
  credential_store : &@oauth.ProviderCredentialStore?,
) -> @oauth.Credential raise @posoco.CompositionError {
  let oauth = CodexOAuth::CodexOAuth(transport=oauth_transport)
  let renewed = oauth.refresh(credential) catch {
    err => raise codex_renewal_failed_error(err)
  }
  match credential_store {
    Some(store) =>
      // Persist under the router provider id — the same key login writes.
      store.write("openai", @oauth.ProviderCredential::OAuth(renewed)) catch {
        _ => ()
      }
    None => ()
  }
  renewed
}

///|
/// Fetch the Codex model catalog with load-time renewal. An expired stored
/// access token renews before the request; a 401 rejection renews once and
/// retries once. Returns the models together with the credential that served
/// the successful request so the rebuilt slots carry fresh tokens too.
async fn refresh_codex_models_with_renewal(
  transport : &OpenAIModelsHttpTransport,
  oauth_transport : &@oauth.OAuthHttpTransport?,
  credential : @oauth.Credential,
  credential_store : &@oauth.ProviderCredentialStore?,
) -> (Array[CodexModelInfo], @oauth.Credential) raise @posoco.CompositionError {
  let mut active = credential
  let mut renewed = false
  if active.is_expired(openai_now_epoch_secs()) {
    active = renew_codex_credential(oauth_transport, active, credential_store)
    renewed = true
  }
  let models = fetch_codex_models_typed_with_transport(
    transport,
    codex_oauth_api_base(),
    active.access_token,
    codex_account_id_of(active),
    openai_codex_models_client_version(),
  ) catch {
    ModelsFetchError::HttpStatus(status=401, ..) => {
      // The renewal already ran once (expired pre-check or a prior 401);
      // a second rejection is not recoverable by renewing again.
      if renewed {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_openai",
          detail="Codex access token rejected after renewal (HTTP 401); browser re-login required",
        )
      }
      let refreshed = renew_codex_credential(
        oauth_transport, active, credential_store,
      )
      active = refreshed
      renewed = true
      fetch_codex_models_typed_with_transport(
        transport,
        codex_oauth_api_base(),
        refreshed.access_token,
        codex_account_id_of(refreshed),
        openai_codex_models_client_version(),
      ) catch {
        err => raise codex_models_refresh_failed_error(err)
      }
    }
    err => raise codex_models_refresh_failed_error(err)
  }
  (models, active)
}
