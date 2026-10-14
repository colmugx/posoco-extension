///|
/// Slot-level context-window facts: provider-declared capacity, disk-cache
/// restoration for offline builds, and the JSON decoding helpers shared by
/// config sources and discovery records.

///|
fn positive_window(value : Int32?) -> Int32? {
  match value {
    Some(n) if n > 0 => Some(n)
    _ => None
  }
}

///|
pub fn context_window_integer(value : Json?) -> Int32? {
  match value {
    Some(Json::Number(n, ..)) if n > 0.0 && n <= 2147483647.0 => {
      let integer = n.to_int()
      if integer.to_double() == n {
        Some(integer)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
/// Only discovery facts can be restored as provider metadata. Derived windows
/// must not become authoritative merely by passing through the disk cache.
pub fn cached_provider_context_window(
  records : Json?,
  model_id : String,
  metadata_provider_id? : String,
) -> Int32? {
  guard records is Some(Json::Array(items)) else { return None }
  for item in items {
    if item is Json::Object(fields) &&
      fields.get("model_id") == Some(Json::string(model_id)) {
      if metadata_provider_id is Some(expected) &&
        fields.get("metadata_provider_id") is Some(Json::String(actual)) &&
        expected != actual {
        return None
      }
      match fields.get("context_window_source") {
        None
        | Some(Json::String("provider"))
        | Some(Json::String("provider_cache")) =>
          return context_window_integer(fields.get("context_window"))
        _ => return None
      }
    }
  }
  None
}

///|
fn restore_slot_window(slot : ModelSlot, records : Json?) -> ModelSlot {
  if positive_window(slot.context_window) is Some(_) ||
    positive_window(slot.port.provider_config().context_window) is Some(_) {
    return slot
  }
  guard cached_provider_context_window(
      records,
      slot.model_id,
      metadata_provider_id=slot.metadata_provider_id.unwrap_or(slot.provider_id),
    )
    is Some(window) else {
    return slot
  }
  {
    ..slot,
    context_window: Some(window),
    context_window_source: "provider_cache",
    rebuild_on_credential: slot.rebuild_on_credential.map(rebuild => {
      fn(credential) { restore_slot_window(rebuild(credential), records) }
    }),
    rebuild_on_api_key: slot.rebuild_on_api_key.map(rebuild => {
      fn(credential) { restore_slot_window(rebuild(credential), records) }
    }),
    rebuild_on_effort: slot.rebuild_on_effort.map(rebuild => {
      fn(effort) { restore_slot_window(rebuild(effort), records) }
    }),
  }
}

///|
pub fn ProviderModelCatalog::with_cached_context_windows(
  self : ProviderModelCatalog,
  records : Json?,
) -> ProviderModelCatalog {
  { ..self, slots: self.slots.map(slot => restore_slot_window(slot, records)), }
}
