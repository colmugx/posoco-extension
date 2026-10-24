///|
/// Canonical credential-store key for the hosted TypeSafe service.
pub fn typesafe_credential_id() -> String {
  "typesafe"
}

///|
/// Configuration for the TypeSafe Jev Decision API.
pub(all) struct TypesafeConfig {
  /// Optional direct API-key fallback for standalone hosts. When a canonical
  /// ProviderCredentialStore is injected into TypesafeDecisionPort, a stored
  /// credential takes precedence over this value.
  api_key : String
  /// Jev model identifier. "jev-latest" tracks the current hosted model.
  model : String
  /// API base URL without the endpoint path.
  base_url : String
  /// Per-request timeout in milliseconds.
  timeout_ms : Int32
} derive(Eq, Debug)

///|
pub fn TypesafeConfig::TypesafeConfig(
  api_key : String,
  model~ : String = "jev-latest",
  base_url~ : String = "https://api.typesafe.ai",
  timeout_ms~ : Int32 = 30000,
) -> TypesafeConfig {
  if model.trim().length() == 0 {
    abort("posoco-ext-typesafe: model must not be empty")
  }
  if base_url.trim().length() == 0 {
    abort("posoco-ext-typesafe: base_url must not be empty")
  }
  if timeout_ms <= 0 {
    abort("posoco-ext-typesafe: timeout_ms must be positive")
  }
  { api_key, model, base_url, timeout_ms, }
}

///|
/// Construct a Jev config that resolves its secret exclusively from an
/// injected ProviderCredentialStore.
pub fn TypesafeConfig::stored(
  model~ : String = "jev-latest",
  base_url~ : String = "https://api.typesafe.ai",
  timeout_ms~ : Int32 = 30000,
) -> TypesafeConfig {
  TypesafeConfig("", model~, base_url~, timeout_ms~)
}

///|
/// Thin provider adapter. Consumer policy stays outside this type. Credential
/// persistence is host-owned and injected through the provider-neutral oauth
/// package; this extension never depends on a concrete file/keychain backend.
pub(all) struct TypesafeDecisionPort {
  config : TypesafeConfig
  credential_store : &@oauth.ProviderCredentialStore?
  credential_id : String
}

///|
pub fn TypesafeDecisionPort::TypesafeDecisionPort(
  config : TypesafeConfig,
  credential_store~ : &@oauth.ProviderCredentialStore? = None,
  credential_id~ : String = "typesafe",
) -> TypesafeDecisionPort {
  if credential_id.trim().length() == 0 {
    abort("posoco-ext-typesafe: credential_id must not be empty")
  }
  { config, credential_store, credential_id, }
}

///|
/// Resolve the effective TypeSafe API key without exposing it to consumers.
/// A canonical tagged credential is authoritative when present. In particular,
/// an explicitly stored OAuth credential must not silently fall back to a
/// stale config API key.
async fn TypesafeDecisionPort::resolve_api_key(
  self : TypesafeDecisionPort,
) -> String raise @posoco.DecisionError {
  match self.credential_store {
    Some(store) => {
      let stored = store.read(self.credential_id) catch {
        _ =>
          raise @posoco.DecisionError::Transport(
            "TypeSafe Jev credential store read failed",
          )
      }
      match stored {
        Some(@oauth.ProviderCredential::ApiKey(credential)) => {
          if credential.secret.trim().length() == 0 {
            raise @posoco.DecisionError::RequestBuild(
              "TypeSafe Jev stored API-key credential is empty",
            )
          }
          return credential.secret
        }
        Some(@oauth.ProviderCredential::OAuth(_)) =>
          raise @posoco.DecisionError::RequestBuild(
            "TypeSafe Jev credential '" +
            self.credential_id +
            "' must be an API key",
          )
        None => ()
      }
    }
    None => ()
  }
  if self.config.api_key.trim().length() > 0 {
    return self.config.api_key
  }
  raise @posoco.DecisionError::RequestBuild(
    "TypeSafe Jev API key is not configured (credential id '" +
    self.credential_id +
    "')",
  )
}
