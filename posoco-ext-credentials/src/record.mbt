///|
/// record.mbt — Backend-neutral codec for the canonical tagged credential
/// record.
///
/// Every `@oauth.ProviderCredentialStore` backend (files today, OS secret
/// managers next) persists the same tagged JSON record; only the storage
/// mechanism differs. Keeping the codec here guarantees all backends agree on
/// the durable shape, and keeps the parsing semantics (typed error, never
/// silent fallback) in one place.

///|
/// Encode a credential as the canonical tagged record string. The record
/// carries an explicit method tag, so a provider which supports both OAuth
/// and API keys has one durable source of truth across recomposition and
/// process restarts.
pub fn encode_provider_credential(
  credential : @oauth.ProviderCredential,
) -> String {
  credential.to_json().stringify()
}

///|
/// Parse one tagged credential record. Malformed records raise a typed
/// composition error without including secret values.
pub fn parse_provider_credential(
  json : Json,
  provider_id : String,
) -> @oauth.ProviderCredential raise @posoco.CompositionError {
  match @oauth.ProviderCredential::from_json(json) {
    Some(value) => value
    None =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco-ext-credentials",
        detail="credential record has an invalid tagged shape for provider " +
          provider_id,
      )
  }
}

///|
/// Parse one tagged credential record from its persisted text form. An
/// invalid-JSON failure and an invalid-shape failure carry distinct details
/// so store diagnostics can point at the real corruption.
pub fn parse_provider_credential_text(
  text : String,
  provider_id : String,
) -> @oauth.ProviderCredential raise @posoco.CompositionError {
  let json = @json.parse(text) catch {
    _ =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco-ext-credentials",
        detail="credential record is not valid JSON for provider " + provider_id,
      )
  }
  parse_provider_credential(json, provider_id)
}
