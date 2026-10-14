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
