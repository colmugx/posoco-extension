///|
/// Whitebox tests for the exemption filter: a report's authority comes from
/// the publisher namespace the envelope carries, never from the payload, so
/// core (`Posoco`) notifications can never exempt a tool.

///|
test "a core-namespaced report exempts nothing" {
  let policy = PermissionPolicy::PermissionPolicy(ReadOnly)
  let envelope = @posoco.EventEnvelope::EventEnvelope(
    namespace_=@posoco.EventNamespace::Posoco,
    event=@kit_events.ToolExemptions({ tools: ["enter_plan_mode"], }),
  )
  policy.record_exemptions(envelope)
  assert_true(policy.exempted.is_empty())
}

///|
test "an extension-namespaced report records the reporting extension" {
  let policy = PermissionPolicy::PermissionPolicy(ReadOnly)
  let envelope = @posoco.EventEnvelope::EventEnvelope(
    namespace_=@posoco.EventNamespace::Extension("posoco_ext_plan"),
    event=@kit_events.ToolExemptions({
      tools: ["enter_plan_mode", "exit_plan_mode"],
    }),
  )
  policy.record_exemptions(envelope)
  assert_eq(policy.exempted.get("enter_plan_mode"), Some("posoco_ext_plan"))
  assert_eq(policy.exempted.get("exit_plan_mode"), Some("posoco_ext_plan"))
}
