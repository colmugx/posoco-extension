///|
pub(all) struct ContextWindowReading {
  tokens : Int32
  source : String
  stale : Bool
} derive(Eq, Debug)

///|
pub extend ContextWindowReading with Eq::{equal, not_equal}

///|
pub extend ContextWindowReading with @moonbitlang/core/debug.Debug::{to_repr}

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
/// An explicit override applies to one configured model, never its siblings.
pub fn ProviderConfigSource::context_window_setting(
  self : ProviderConfigSource,
  manifest_id~ : String,
) -> Int32? raise @posoco.CompositionError {
  match self.setting("context_window") {
    None => None
    Some(value) =>
      match context_window_integer(Some(value)) {
        Some(n) => Some(n)
        None =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id~,
            detail="context_window must be a positive integer within Int range",
          )
      }
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

///|
pub async fn RouterModelPort::refresh_model_metadata(
  self : RouterModelPort,
) -> Unit noraise {
  match self.model_metadata {
    Some(metadata) => {
      let providers : Array[String] = []
      for slot in self.list_slots() {
        let id = slot.metadata_provider_id.unwrap_or(slot.provider_id)
        if id != "" && !providers.contains(id) {
          providers.push(id)
        }
      }
      metadata.refresh(providers)
      if self.active_slot_opt() is Some(slot) &&
        self.context_window_reading(slot).source == "fallback" {
        metadata.report_fallback(slot.provider_id, slot.model_id)
      }
    }
    None => ()
  }
}

///|
pub fn RouterModelPort::context_window_reading(
  self : RouterModelPort,
  slot : ModelSlot,
) -> ContextWindowReading {
  if slot.context_window_source == "configured" &&
    positive_window(slot.context_window) is Some(tokens) {
    return { tokens, source: "configured", stale: false, }
  }
  if positive_window(slot.port.provider_config().context_window) is Some(tokens) {
    return {
      tokens,
      source: if slot.context_window == Some(tokens) {
        slot.context_window_source
      } else {
        "provider"
      },
      stale: false,
    }
  }
  if positive_window(slot.context_window) is Some(tokens) {
    return { tokens, source: slot.context_window_source, stale: false, }
  }
  match self.model_metadata {
    Some(metadata) =>
      metadata.lookup(
        slot.metadata_provider_id.unwrap_or(slot.provider_id),
        slot.model_id,
      )
    None => { tokens: 500_000, source: "fallback", stale: false, }
  }
}
