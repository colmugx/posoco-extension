///|
/// Provider-owned model catalog.
///
/// A provider extension builds this value after resolving its own endpoint,
/// protocol, credentials, model ids, and capability rules. The router only
/// validates composition and aggregates the resulting slots; it never parses
/// provider configuration.
pub(all) struct ProviderModelCatalog {
  provider_id : String
  slots : Array[ModelSlot]
  capabilities : Array[String]
}

///|
/// Construct and validate a provider catalog atomically.
pub fn ProviderModelCatalog::ProviderModelCatalog(
  provider_id~ : String,
  slots~ : Array[ModelSlot],
  capabilities? : Array[String] = [],
) -> ProviderModelCatalog raise @posoco.CompositionError {
  if provider_id.length() == 0 {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_llm",
      detail="provider catalog id must not be empty",
    )
  }
  if slots.is_empty() {
    raise @posoco.CompositionError::EmptyPort(
      "posoco_ext_llm.catalog." + provider_id,
    )
  }
  let seen : Map[String, Bool] = Map::from_array([])
  for slot in slots {
    if slot.id.length() == 0 {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_llm",
        detail="provider catalog slot id must not be empty",
      )
    }
    if slot.provider_id != provider_id {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_llm",
        detail="slot provider id does not match catalog provider: " + slot.id,
      )
    }
    if seen.contains(slot.id) {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_llm",
        detail="duplicate provider catalog slot id: " + slot.id,
      )
    }
    seen[slot.id] = true
  }
  { provider_id, slots, capabilities }
}

///|
/// Provider id for diagnostics and UI labels.
pub fn ProviderModelCatalog::provider_id(self : ProviderModelCatalog) -> String {
  self.provider_id
}

///|
/// Provider-owned model slots in declaration order.
pub fn ProviderModelCatalog::slots(
  self : ProviderModelCatalog,
) -> Array[ModelSlot] {
  self.slots.copy()
}

///|
/// Provider capabilities such as `chat`, `streaming`, or provider-native
/// operations. Cetas treats these as opaque capability identifiers.
pub fn ProviderModelCatalog::capabilities(
  self : ProviderModelCatalog,
) -> Array[String] {
  self.capabilities.copy()
}

///|
/// Authentication methods advertised by the provider's slots. This is
/// derived from extension-owned factories so a host receives a generic
/// capability list without inspecting provider configuration.
pub fn ProviderModelCatalog::auth_methods(
  self : ProviderModelCatalog,
) -> Array[AuthMethod] {
  let result : Array[AuthMethod] = []
  for slot in self.slots {
    match slot.api_key {
      Some(_) =>
        if !result.contains(AuthMethod::ApiKey) {
          result.push(AuthMethod::ApiKey)
        }
      None => ()
    }
    match slot.oauth {
      Some(_) =>
        if !result.contains(AuthMethod::OAuth) {
          result.push(AuthMethod::OAuth)
        }
      None => ()
    }
  }
  result
}
