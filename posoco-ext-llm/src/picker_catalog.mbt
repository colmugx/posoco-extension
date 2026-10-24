///|
/// Current router slots in the shared picker shape:
/// `{id, provider, model, label, efforts, default_effort, context_window,
/// capabilities}`.
///
/// `/model` owns the interactive catalog (`slot_catalog_json`, with quota,
/// pricing and group tabs). Hosts that project the router catalog into a
/// non-command surface — the Board ticket model picker — need the same
/// selection facts without the interactive extras, so this helper stays a
/// projection of `list_slots()` and never re-derives a slot's identity.
///
/// Field facts:
/// - `id` is the slot id and is the only value a caller may pin; it is opaque
///   and never split on `/`.
/// - `efforts` is the provider-declared effort ladder verbatim; an empty
///   ladder means the slot accepts no effort override.
/// - `context_window` is the same resolved window `/model` reports (providers,
///   configured values, cached metadata, then the display fallback).
pub fn RouterModelPort::picker_catalog_json(
  self : RouterModelPort,
) -> Array[Json] {
  let entries : Array[Json] = []
  for slot in self.list_slots() {
    entries.push(
      Json::object({
        "id": Json::string(slot.id),
        "label": Json::string(slot.label),
        "provider": Json::string(slot.provider_id),
        "model": Json::string(slot.model_id),
        "efforts": Json::array(
          slot.thinking_efforts.map(fn(effort) { Json::string(effort) }),
        ),
        "default_effort": match slot.default_effort {
          Some(effort) => Json::string(effort)
          None => Json::null()
        },
        "context_window": Json::number(
          self.context_window_reading(slot).tokens.to_double(),
        ),
        "capabilities": Json::array(
          slot.capabilities.map(fn(capability) { Json::string(capability) }),
        ),
      }),
    )
  }
  entries
}
