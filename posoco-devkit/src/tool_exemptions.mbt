///|
/// `tool_exemptions` — a bus topic convention for cross-extension gate
/// exemptions.
///
/// An extension whose tools carry their own governance (posoco-ext-plan's
/// enter/exit pair, where the real decision happens at the plan-review
/// seam) reports those tool names so a peer gate (posoco-ext-permission's
/// approval gate) lets them bypass its own checks. The reporting extension
/// publishes at construction; the receiving gate must already be
/// subscribed — the bus is fire-and-forget, a report with no subscriber is
/// dropped, so host composition order matters.
///
/// This is a trust channel, not a security boundary. Nothing at runtime
/// verifies that a report names only the reporter's own tools or that the
/// named tools are safe. The guarantee is code review: the developer
/// wiring the bus reads what each composed extension reports. Do not wire
/// an extension you do not trust to this degree.

///|
/// The topic string of the convention (see `bus.mbt` for the topic model).
pub let tool_exemptions_topic : String = "tool_exemptions"

///|
/// Publish an exemption report: `source` is the reporting extension's id,
/// `tools` the exact tool names (no patterns) that subscribing gates let
/// bypass.
pub fn publish_tool_exemptions(
  bus : EventBus,
  source~ : String,
  tools~ : Array[String],
) -> Unit {
  bus.publish({
    source,
    topic: tool_exemptions_topic,
    data: Json::object({ "tools": Json::array(tools.map(Json::string)) }),
  })
}

///|
/// Decode an exemption-report payload. `None` when the data does not match
/// the convention (not an object, missing or non-array `tools`, non-string
/// entries) — a gate treats that as "nothing reported" and moves on.
pub fn parse_tool_exemptions(data : Json) -> Array[String]? {
  match data {
    Object(fields) =>
      match fields.get("tools") {
        Some(Array(entries)) => {
          let names : Array[String] = []
          for entry in entries {
            match entry {
              String(name) => names.push(name)
              _ => return None
            }
          }
          Some(names)
        }
        _ => None
      }
    _ => None
  }
}
