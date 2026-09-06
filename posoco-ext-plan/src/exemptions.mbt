///|
/// Plan's own half of the `tool_exemptions` bus convention: this extension
/// publishes the tool names that carry their own governance — the
/// enter/exit pair, whose real decision lives at the plan-review seam —
/// so a subscribed approval gate lets them bypass its checks. The bus is
/// fire-and-forget: the receiving gate must already be subscribed, i.e.
/// hosts construct the gate before this extension. A trust channel, not a
/// security boundary — nothing at runtime verifies the report; the
/// guarantee is code review of the composed wiring.

///|
/// The topic string this extension publishes exemption reports on; the
/// payload is `{"tools": [string, ...]}`, pinned by tests here and in the
/// subscriber.
let tool_exemptions_topic : String = "tool_exemptions"

///|
/// Publish one exemption report: `tools` are the exact tool names (no
/// patterns) that subscribing gates let bypass.
fn publish_tool_exemptions(
  bus : @devkit.EventBus,
  tools~ : Array[String],
) -> Unit {
  bus.publish({
    source: "posoco_ext_plan",
    topic: tool_exemptions_topic,
    data: Json::object({ "tools": Json::array(tools.map(Json::string)) }),
  })
}
