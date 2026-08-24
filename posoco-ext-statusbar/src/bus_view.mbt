///|
/// BusSubscriber view: consume peer-published status facts from the shared
/// `@devkit.EventBus` (domain-event style).
///
/// Convention — topic `"status"`, payload a JSON object mapping segment id
/// to display text, or `null` to drop that segment:
///
/// ```json
/// {"topic": "status", "data": {"cache": "62% (48/77)", "sprint": null}}
/// ```
///
/// The bar receives every bus event and reacts only to what it understands:
/// unknown topics are ignored; non-object payloads and non-string /
/// non-null field values are ignored field-by-field (the bus is a
/// notification channel with no error path). One event re-renders at most
/// once, no matter how many segments it updates.
pub const STATUSBAR_TOPIC = "status"

///|
pub impl @devkit.BusSubscriber for StatusBar with fn on_bus_event(
  self : StatusBar,
  event : @devkit.BusEvent,
) -> Unit {
  if event.topic != STATUSBAR_TOPIC {
    return
  }
  let fields = match event.data {
    Json::Object(fields) => fields
    _ => return
  }
  let mut changed = false
  for id, value in fields {
    match value {
      Json::String(text) => {
        self.state.custom[id] = text
        changed = true
      }
      Json::Null =>
        if self.state.custom.contains(id) {
          ignore(self.state.custom.remove(id))
          changed = true
        }
      _ => ()
    }
  }
  if changed {
    self.render()
  }
}
