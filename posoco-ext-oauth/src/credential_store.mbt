///|
/// credential_store.mbt — persistent credential storage abstraction.

///|
/// Stores OAuth credentials keyed by provider_id. Hosts implement this
/// (file-based, keychain, etc.); providers are agnostic to the storage.
pub(open) trait CredentialStore {
  /// Read the stored credential for a provider. None if not stored or invalid.
  async fn read(Self, provider_id : String) -> Credential? raise OAuthError

  /// Persist a credential for a provider. Overwrites if exists.
  async fn write(Self, provider_id : String, credential : Credential) -> Unit raise OAuthError

  /// Delete the stored credential for a provider (logout).
  async fn delete(Self, provider_id : String) -> Unit raise OAuthError
}

///|
/// In-memory credential store for tests/dev. Not persistent.
pub(all) struct InMemoryCredentialStore {
  credentials : Map[String, Credential]
}

///|
pub fn InMemoryCredentialStore::new() -> InMemoryCredentialStore {
  { credentials: Map([]) }
}

///|
pub impl CredentialStore for InMemoryCredentialStore with fn read(
  self : InMemoryCredentialStore,
  provider_id : String,
) -> Credential? {
  match self.credentials.get(provider_id) {
    Some(c) => Some(c)
    None => None
  }
}

///|
pub impl CredentialStore for InMemoryCredentialStore with fn write(
  self : InMemoryCredentialStore,
  provider_id : String,
  credential : Credential,
) -> Unit {
  self.credentials[provider_id] = credential
}

///|
pub impl CredentialStore for InMemoryCredentialStore with fn delete(
  self : InMemoryCredentialStore,
  provider_id : String,
) -> Unit {
  self.credentials.remove(provider_id)
}
