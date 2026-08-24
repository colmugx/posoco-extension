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
/// Canonical provider credential storage.  Unlike the legacy OAuth-only and
/// API-key-only stores below, this contract has one tagged record per provider
/// and therefore preserves the user's explicit authentication-method choice
/// across process restarts and host recomposition.
pub(open) trait ProviderCredentialStore {
  /// Read the active tagged credential for a provider. Missing is unconfigured.
  async fn read(Self, provider_id : String) -> ProviderCredential? raise OAuthError

  /// Atomically replace the active tagged credential for a provider.
  async fn write(Self, provider_id : String, credential : ProviderCredential) -> Unit raise OAuthError

  /// Delete the active tagged credential for a provider.
  async fn delete(Self, provider_id : String) -> Unit raise OAuthError
}

///|
/// In-memory canonical store used by router and host conformance tests.
pub(all) struct InMemoryProviderCredentialStore {
  credentials : Map[String, ProviderCredential]
}

///|
pub fn InMemoryProviderCredentialStore::InMemoryProviderCredentialStore() -> InMemoryProviderCredentialStore {
  { credentials: Map([]) }
}

///|
pub impl ProviderCredentialStore for InMemoryProviderCredentialStore with fn read(
  self : InMemoryProviderCredentialStore,
  provider_id : String,
) -> ProviderCredential? {
  self.credentials.get(provider_id)
}

///|
pub impl ProviderCredentialStore for InMemoryProviderCredentialStore with fn write(
  self : InMemoryProviderCredentialStore,
  provider_id : String,
  credential : ProviderCredential,
) -> Unit {
  self.credentials[provider_id] = credential
}

///|
pub impl ProviderCredentialStore for InMemoryProviderCredentialStore with fn delete(
  self : InMemoryProviderCredentialStore,
  provider_id : String,
) -> Unit {
  self.credentials.remove(provider_id)
}

///|
/// In-memory credential store for tests/dev. Not persistent.
pub(all) struct InMemoryCredentialStore {
  credentials : Map[String, Credential]
}

///|
pub fn InMemoryCredentialStore::InMemoryCredentialStore() -> InMemoryCredentialStore {
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

///|
/// Stores provider-neutral API-key credentials. Hosts may back this with the
/// same secure store as OAuth credentials, but the two contracts remain
/// separate so providers never receive an untyped secret map.
pub(open) trait ApiKeyStore {
  async fn read(Self, provider_id : String) -> ApiKeyCredential? raise OAuthError
  async fn write(Self, provider_id : String, credential : ApiKeyCredential) -> Unit raise OAuthError
  async fn delete(Self, provider_id : String) -> Unit raise OAuthError
}

///|
/// In-memory API-key store for deterministic extension tests.
pub(all) struct InMemoryApiKeyStore {
  credentials : Map[String, ApiKeyCredential]
}

///|
pub fn InMemoryApiKeyStore::InMemoryApiKeyStore() -> InMemoryApiKeyStore {
  { credentials: Map([]) }
}

///|
pub impl ApiKeyStore for InMemoryApiKeyStore with fn read(
  self : InMemoryApiKeyStore,
  provider_id : String,
) -> ApiKeyCredential? {
  self.credentials.get(provider_id)
}

///|
pub impl ApiKeyStore for InMemoryApiKeyStore with fn write(
  self : InMemoryApiKeyStore,
  provider_id : String,
  credential : ApiKeyCredential,
) -> Unit {
  self.credentials[provider_id] = credential
}

///|
pub impl ApiKeyStore for InMemoryApiKeyStore with fn delete(
  self : InMemoryApiKeyStore,
  provider_id : String,
) -> Unit {
  self.credentials.remove(provider_id)
}
