///|
/// The permission gate's own half of the `tool_exemptions` protocol: tools
/// reported exempt by composed extensions skip this gate entirely.
/// A trust channel, not a security boundary — nothing at runtime verifies
/// that a report names only the reporter's own tools or that they are
/// safe; the guarantee is code review of the composed wiring.

///|
/// Record one exemption report: every reported tool name maps to the
/// reporting extension's id, and entries accumulate — there is no
/// revocation.
///
/// The report arrives as the closed `@kit_events.ToolExemptions` payload
/// (legacy topic `"tool_exemptions"`, legacy Json `{"tools": [string, ...]}`)
/// and the reporter's identity is the capability namespace the envelope
/// carries (`Extension(id)`) — the typed replacement for the legacy
/// `BusEvent.source`. Core (`Posoco`) notifications hold no exemption
/// authority, so they are ignored.
fn PermissionPolicy::record_exemptions(
  self : PermissionPolicy,
  envelope : @posoco.EventEnvelope,
) -> Unit {
  match envelope.event {
    @kit_events.ToolExemptions(payload) =>
      match @kit_events.publisher_id(envelope) {
        Some(source) =>
          for name in payload.tools {
            self.exempted[name] = source
          }
        None => ()
      }
    // Every other protocol event is somebody else's business; the gate reads
    // only exemption reports and ignores the rest.
    _ => ()
  }
}
