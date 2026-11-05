///|
/// Whitebox tests for the status publisher path (`events_system.mbt`):
/// `publish_status_*` publishes `@kit_events.StatusChanged` through the process
/// default `EventSystem`.
///
/// The payload test pins the invariant that matters: for the same arguments the
/// typed payload carries exactly the fields the protocol documents.

///|
/// Collect every protocol event delivered by the system it listens on.
priv struct StatusSink {
  envelopes : Array[@events.EventEnvelope]
}

///|
fn StatusSink::StatusSink() -> StatusSink {
  { envelopes: [], }
}

///|
/// Register a fresh system as the process default and start capturing.
fn capture_system() -> (StatusSink, @posoco.EventSystem) {
  let system = @posoco.EventSystem()
  events_system_register(system)
  let sink = StatusSink::StatusSink()
  match system.subscribe(fn(envelope) { sink.envelopes.push(envelope) }) {
    Ok(_) => ()
    Err(_) => abort("subscribe on a fresh EventSystem failed")
  }
  (sink, system)
}

///|
test "register publishes StatusChanged through the default system" {
  let (sink, _system) = capture_system()
  publish_status_register(
    source="posoco_ext_plan",
    segment="plan",
    label="mode",
    priority=10,
    value="on",
    color="accent",
  )
  assert_eq(sink.envelopes.length(), 1)
  assert_eq(
    @kit_events.status_changed_of(sink.envelopes[0]),
    Some(
      @kit_events.Register(
        segment="plan",
        label=Some("mode"),
        priority=10,
        value=Some("on"),
        color=Some("accent"),
      ),
    ),
  )
  // The capability is minted for `source`, so the publisher identity survives
  // on the envelope; subscribers filter on this.
  assert_eq(
    @kit_events.publisher_id(sink.envelopes[0]),
    Some("posoco_ext_plan"),
  )
  assert_eq(
    sink.envelopes[0].namespace_of(),
    @events.Extension("posoco_ext_plan"),
  )
}

///|
test "register without optionals publishes absent fields as None" {
  let (sink, _system) = capture_system()
  publish_status_register(source="ext", segment="ttft")
  assert_eq(
    @kit_events.status_changed_of(sink.envelopes[0]),
    Some(
      @kit_events.Register(
        segment="ttft",
        label=None,
        priority=0,
        value=None,
        color=None,
      ),
    ),
  )
}

///|
test "update and unregister publish the matching op" {
  let (sink, _system) = capture_system()
  publish_status_update(source="ext", segment="session", value="s_42")
  publish_status_unregister(source="ext", segment="session")
  assert_eq(
    @kit_events.status_changed_of(sink.envelopes[0]),
    Some(@kit_events.Update(segment="session", value="s_42")),
  )
  assert_eq(
    @kit_events.status_changed_of(sink.envelopes[1]),
    Some(@kit_events.Unregister(segment="session")),
  )
}

///|
test "the published payloads carry the documented field names and values" {
  let (sink, _system) = capture_system()
  publish_status_register(
    source="ext",
    segment="plan",
    label="mode",
    priority=10,
    value="on",
  )
  publish_status_update(source="ext", segment="plan", value="off")
  publish_status_unregister(source="ext", segment="plan")
  publish_status_register(source="ext", segment="plan", color="warning")
  let expected : Array[@kit_events.StatusOp] = [
    @kit_events.Register(
      segment="plan",
      label=Some("mode"),
      priority=10,
      value=Some("on"),
      color=None,
    ),
    @kit_events.Update(segment="plan", value="off"),
    @kit_events.Unregister(segment="plan"),
    @kit_events.Register(
      segment="plan",
      label=None,
      priority=0,
      value=None,
      color=Some("warning"),
    ),
  ]
  assert_eq(sink.envelopes.length(), expected.length())
  for index, op in expected {
    assert_eq(@kit_events.status_changed_of(sink.envelopes[index]), Some(op))
  }
}

///|
test "a closed system makes publication a silent no-op" {
  let (sink, system) = capture_system()
  assert_true(system.close() is Ok(_))
  publish_status_register(source="ext", segment="plan", value="on")
  publish_status_update(source="ext", segment="plan", value="off")
  publish_status_unregister(source="ext", segment="plan")
  assert_eq(sink.envelopes.length(), 0)
}
