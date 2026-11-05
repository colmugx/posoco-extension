///|
/// Plan's own half of the `tool_exemptions` protocol: this extension
/// publishes the tool names that carry their own governance — the
/// enter/exit pair, whose real decision lives at the plan-review seam —
/// so a subscribed approval gate lets them bypass its checks. The channel
/// is fire-and-forget: the receiving gate must already be subscribed, i.e.
/// hosts wire the gate before this extension publishes. A trust channel,
/// not a security boundary — nothing at runtime verifies the report; the
/// guarantee is code review of the composed wiring.

///|
/// Publish one exemption report: `tools` are the exact tool names (no
/// patterns) that subscribing gates let bypass.
///
/// The report is the closed `@kit_events.ToolExemptions` payload and rides the
/// capability the host minted for this extension, so subscribers see it
/// stamped with `Extension("posoco_ext_plan")`.
fn publish_tool_exemptions(
  events : @posoco.Events,
  tools~ : Array[String],
) -> Unit {
  ignore(events.publish(@kit_events.ToolExemptions({ tools, })))
}
