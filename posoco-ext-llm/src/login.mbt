///|
/// Provider-neutral `/login` orchestration.
///
/// The router exposes authentication capabilities and delegates prompt,
/// validation, credential interpretation, and slot rebuilding to provider
/// extensions. It never parses provider settings or endpoint details.

///|
priv struct LoginSelection {
  provider_id : String?
  method : String?
}

///|
fn optional_login_string(
  fields : Map[String, Json],
  key : String,
) -> String? raise @posoco.CommandError {
  match fields.get(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CommandError::InvalidArgs(
          reason="/login " + key + " must be a non-empty string",
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/login " + key + " must be a string",
      )
  }
}

///|
fn login_command_selection(
  args : Json,
) -> LoginSelection raise @posoco.CommandError {
  match args {
    Json::Null => { provider_id: None, method: None }
    Json::String(provider_id) =>
      if provider_id.length() == 0 {
        { provider_id: None, method: None }
      } else {
        { provider_id: Some(provider_id), method: None }
      }
    Json::Object(fields) =>
      {
        provider_id: optional_login_string(fields, "provider"),
        method: optional_login_string(fields, "method"),
      }
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/login expects no arguments, a provider string, or {provider, method}",
      )
  }
}

///|
fn oauth_error_summary(err : @oauth.OAuthError) -> String {
  match err {
    @oauth.OAuthError::AuthPending => "auth_pending"
    @oauth.OAuthError::SlowDown => "slow_down"
    @oauth.OAuthError::AccessDenied => "access_denied"
    @oauth.OAuthError::ExpiredToken => "expired_token"
    @oauth.OAuthError::InvalidGrant => "invalid_grant"
    @oauth.OAuthError::HttpError(_) => "http_error"
    @oauth.OAuthError::ParseError(_) => "parse_error"
    @oauth.OAuthError::Cancelled => "cancelled"
  }
}

///|
fn auth_methods_for_slot(slot : ModelSlot) -> Array[AuthMethod] {
  let result : Array[AuthMethod] = []
  match slot.api_key {
    Some(_) => result.push(AuthMethod::ApiKey)
    None => ()
  }
  match slot.oauth {
    Some(_) => result.push(AuthMethod::OAuth)
    None => ()
  }
  result
}

///|
fn auth_methods_json(methods : Array[AuthMethod]) -> Json {
  let values : Array[Json] = []
  for method in methods {
    values.push(Json::string(method.to_id()))
  }
  Json::array(values)
}

///|
/// List each provider once with its provider-owned auth methods.
pub fn RouterModelPort::list_auth_capabilities(self : RouterModelPort) -> Json {
  let entries : Array[Json] = []
  let seen : Array[String] = []
  for id in self.slot_order {
    match self.slots.get(id) {
      Some(slot) =>
        if !seen.contains(slot.provider_id) {
          seen.push(slot.provider_id)
          entries.push(
            Json::object(
              Map::from_array([
                ("provider", Json::string(slot.provider_id)),
                ("methods", auth_methods_json(auth_methods_for_slot(slot))),
              ]),
            ),
          )
        }
      None =>
        abort(
          "posoco_ext_llm router invariant violated: ordered slot is missing: " +
          id,
        )
    }
  }
  Json::array(entries)
}

///|
/// Backward-compatible OAuth-only provider id list.
pub fn RouterModelPort::list_oauth_provider_ids(
  self : RouterModelPort,
) -> Array[String] {
  let result : Array[String] = []
  for id in self.slot_order {
    match self.slots.get(id) {
      Some(slot) =>
        match slot.oauth {
          Some(_) =>
            if !result.contains(slot.provider_id) {
              result.push(slot.provider_id)
            }
          None => ()
        }
      None =>
        abort(
          "posoco_ext_llm router invariant violated: ordered slot is missing: " +
          id,
        )
    }
  }
  result
}

///|
fn RouterModelPort::find_oauth_provider(
  self : RouterModelPort,
  provider_id : String,
) -> &@oauth.OAuthProvider? {
  for id in self.slot_order {
    match self.slots.get(id) {
      Some(slot) =>
        if slot.provider_id == provider_id {
          match slot.oauth {
            Some(provider) => return Some(provider)
            None => ()
          }
        }
      None =>
        abort(
          "posoco_ext_llm router invariant violated: ordered slot is missing: " +
          id,
        )
    }
  }
  None
}

///|
fn RouterModelPort::find_api_key_provider(
  self : RouterModelPort,
  provider_id : String,
) -> &ApiKeyFactory? {
  for id in self.slot_order {
    match self.slots.get(id) {
      Some(slot) =>
        if slot.provider_id == provider_id {
          match slot.api_key {
            Some(provider) => return Some(provider)
            None => ()
          }
        }
      None =>
        abort(
          "posoco_ext_llm router invariant violated: ordered slot is missing: " +
          id,
        )
    }
  }
  None
}

///|
fn RouterModelPort::rebuild_oauth_slots(
  self : RouterModelPort,
  provider_id : String,
  credential : @oauth.Credential,
) -> Int {
  let replacements : Array[(String, ModelSlot)] = []
  for id in self.slot_order {
    match self.slots.get(id) {
      Some(slot) =>
        if slot.provider_id == provider_id {
          match slot.rebuild_on_credential {
            Some(factory) => replacements.push((id, factory(credential)))
            None => ()
          }
        }
      None =>
        abort(
          "posoco_ext_llm router invariant violated: ordered slot is missing: " +
          id,
        )
    }
  }
  for pair in replacements {
    let (id, replacement) = pair
    self.slots[id] = replacement
  }
  replacements.length()
}

///|
fn RouterModelPort::rebuild_api_key_slots(
  self : RouterModelPort,
  provider_id : String,
  credential : @oauth.ApiKeyCredential,
) -> Int {
  let replacements : Array[(String, ModelSlot)] = []
  for id in self.slot_order {
    match self.slots.get(id) {
      Some(slot) =>
        if slot.provider_id == provider_id {
          match slot.rebuild_on_api_key {
            Some(factory) => replacements.push((id, factory(credential)))
            None => ()
          }
        }
      None =>
        abort(
          "posoco_ext_llm router invariant violated: ordered slot is missing: " +
          id,
        )
    }
  }
  for pair in replacements {
    let (id, replacement) = pair
    self.slots[id] = replacement
  }
  replacements.length()
}

///|
fn RouterModelPort::provider_methods(
  self : RouterModelPort,
  provider_id : String,
) -> Array[AuthMethod] {
  for id in self.slot_order {
    match self.slots.get(id) {
      Some(slot) =>
        if slot.provider_id == provider_id {
          return auth_methods_for_slot(slot)
        }
      None =>
        abort(
          "posoco_ext_llm router invariant violated: ordered slot is missing: " +
          id,
        )
    }
  }
  []
}

///|
fn parse_auth_method(method : String) -> AuthMethod raise @posoco.CommandError {
  match method {
    "oauth" => AuthMethod::OAuth
    "api_key" => AuthMethod::ApiKey
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/login method must be 'oauth' or 'api_key'",
      )
  }
}

///|
fn RouterModelPort::select_auth_method(
  self : RouterModelPort,
  provider_id : String,
  requested : String?,
) -> AuthMethod raise @posoco.CommandError {
  match requested {
    Some(method) => {
      let selected = parse_auth_method(method)
      if !self.provider_methods(provider_id).contains(selected) {
        raise @posoco.CommandError::InvalidArgs(
          reason="provider does not expose auth method: " + method,
        )
      }
      selected
    }
    None => {
      let methods = self.provider_methods(provider_id)
      if methods.length() == 1 {
        methods[0]
      } else if methods.is_empty() {
        raise @posoco.CommandError::InvalidArgs(
          reason="provider has no authentication method: " + provider_id,
        )
      } else {
        raise @posoco.CommandError::InvalidArgs(
          reason="/login requires method for provider " + provider_id,
        )
      }
    }
  }
}

///|
async fn RouterModelPort::invoke_oauth_login(
  self : RouterModelPort,
  provider_id : String,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  let provider = match self.find_oauth_provider(provider_id) {
    Some(provider) => provider
    None =>
      return @posoco.CommandOutcome::Failure(
        reason="provider has no OAuth method: " + provider_id,
      )
  }
  let interaction = match self.auth_interaction {
    Some(interaction) => interaction
    None =>
      raise @posoco.CommandError::ExecutionFailed(
        "OAuth auth interaction is not configured",
      )
  }
  let credential = provider.login(interaction) catch {
    err =>
      raise @posoco.CommandError::ExecutionFailed(
        "OAuth login failed for " +
        provider_id +
        ": " +
        oauth_error_summary(err),
      )
  }
  let credential_provider_id = provider.provider_id()
  match self.provider_credential_store {
    Some(store) =>
      store.write(provider_id, @oauth.ProviderCredential::OAuth(credential)) catch {
        err =>
          raise @posoco.CommandError::ExecutionFailed(
            "OAuth credential persistence failed for " +
            provider_id +
            ": " +
            oauth_error_summary(err),
          )
      }
    None => {
      let store = match self.cred_store {
        Some(store) => store
        None =>
          raise @posoco.CommandError::ExecutionFailed(
            "OAuth credential store is not configured",
          )
      }
      store.write(credential_provider_id, credential) catch {
        err =>
          raise @posoco.CommandError::ExecutionFailed(
            "OAuth credential persistence failed for " +
            provider_id +
            ": " +
            oauth_error_summary(err),
          )
      }
      // Legacy hosts may expose both stores.  A successful explicit login
      // replaces the previous method so a later recomposition cannot silently
      // select OAuth again.
      match self.find_api_key_provider(provider_id) {
        Some(api_key_provider) =>
          match self.api_key_store {
            Some(api_key_store) =>
              api_key_store.delete(api_key_provider.credential_id()) catch {
                err =>
                  raise @posoco.CommandError::ExecutionFailed(
                    "API-key credential cleanup failed for " +
                    provider_id +
                    ": " +
                    oauth_error_summary(err),
                  )
              }
            None => ()
          }
        None => ()
      }
    }
  }
  self.credentials[credential_provider_id] = credential
  let rebuilt = self.rebuild_oauth_slots(provider_id, credential)
  @posoco.CommandOutcome::Success(
    feedback="Logged in to " + provider_id,
    structured=Some(
      Json::object(
        Map::from_array([
          ("provider", Json::string(provider_id)),
          ("method", Json::string("oauth")),
          ("rebuilt_slots", Json::number(rebuilt.to_double())),
        ]),
      ),
    ),
    ui_hint=Some(@posoco.UiHint::RefreshModelList),
  )
}

///|
async fn RouterModelPort::invoke_api_key_login(
  self : RouterModelPort,
  provider_id : String,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  let provider = match self.find_api_key_provider(provider_id) {
    Some(provider) => provider
    None =>
      return @posoco.CommandOutcome::Failure(
        reason="provider has no api_key method: " + provider_id,
      )
  }
  let interaction = match self.auth_prompt {
    Some(interaction) => interaction
    None =>
      raise @posoco.CommandError::ExecutionFailed(
        "API-key auth prompt is not configured",
      )
  }
  let credential = provider.login(interaction) catch {
    err =>
      raise @posoco.CommandError::ExecutionFailed(
        "API-key login failed for " +
        provider_id +
        ": " +
        oauth_error_summary(err),
      )
  }
  let credential_provider_id = provider.credential_id()
  match self.provider_credential_store {
    Some(store) =>
      store.write(provider_id, @oauth.ProviderCredential::ApiKey(credential)) catch {
        err =>
          raise @posoco.CommandError::ExecutionFailed(
            "API-key credential persistence failed for " +
            provider_id +
            ": " +
            oauth_error_summary(err),
          )
      }
    None => {
      let store = match self.api_key_store {
        Some(store) => store
        None =>
          raise @posoco.CommandError::ExecutionFailed(
            "API-key credential store is not configured",
          )
      }
      store.write(credential_provider_id, credential) catch {
        err =>
          raise @posoco.CommandError::ExecutionFailed(
            "API-key credential persistence failed for " +
            provider_id +
            ": " +
            oauth_error_summary(err),
          )
      }
      // Legacy dual stores are reconciled on every explicit method choice.
      match self.find_oauth_provider(provider_id) {
        Some(oauth_provider) =>
          match self.cred_store {
            Some(oauth_store) =>
              oauth_store.delete(oauth_provider.provider_id()) catch {
                err =>
                  raise @posoco.CommandError::ExecutionFailed(
                    "OAuth credential cleanup failed for " +
                    provider_id +
                    ": " +
                    oauth_error_summary(err),
                  )
              }
            None => ()
          }
        None => ()
      }
    }
  }
  self.api_key_credentials[credential_provider_id] = credential
  let rebuilt = self.rebuild_api_key_slots(provider_id, credential)
  @posoco.CommandOutcome::Success(
    feedback="Logged in to " + provider_id,
    structured=Some(
      Json::object(
        Map::from_array([
          ("provider", Json::string(provider_id)),
          ("method", Json::string("api_key")),
          ("rebuilt_slots", Json::number(rebuilt.to_double())),
        ]),
      ),
    ),
    ui_hint=Some(@posoco.UiHint::RefreshModelList),
  )
}

///|
async fn RouterModelPort::invoke_login(
  self : RouterModelPort,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  let selection = login_command_selection(args)
  let provider_id = match selection.provider_id {
    None =>
      return @posoco.CommandOutcome::Success(
        feedback="Available authentication methods",
        structured=Some(self.list_auth_capabilities()),
        ui_hint=Some(@posoco.UiHint::None),
      )
    Some(value) => value
  }
  let method = self.select_auth_method(provider_id, selection.method)
  match method {
    AuthMethod::OAuth => self.invoke_oauth_login(provider_id)
    AuthMethod::ApiKey => self.invoke_api_key_login(provider_id)
  }
}
