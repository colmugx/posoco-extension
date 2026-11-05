///|
/// The `tool_exemptions` announcement moved from a Json payload on the
/// retired devkit topic to the closed `@kit_events.ToolExemptions` record on
/// the `@events` channel. These tests pin the migrated contract: the same
/// tool list, the publisher's identity on the envelope, and the same
/// fire-and-forget silence when no channel exists.

///|
test "constructing the runtime publishes typed tool exemptions" {
  let system = @posoco.EventSystem()
  @devkit.events_system_register(system)
  let envelopes : Array[@posoco.EventEnvelope] = []
  match system.subscribe(fn(envelope) { envelopes.push(envelope) }) {
    Ok(_) => ()
    Err(_) => fail("subscribe on a fresh EventSystem failed")
  }
  let model = @tk.ScriptedModel([])
  let base = @runtime.PortRuntime(model=model as &@posoco.ModelPort)
  let _runtime = @posoco-ext-bunraku.BunrakuRuntime(
    fallback=base as &@runtime.Runtime,
  )
  assert_eq(envelopes.length(), 1)
  assert_eq(@kit_events.publisher_id(envelopes[0]), Some("posoco_ext_bunraku"))
  match @kit_events.tool_exemptions_of(envelopes[0]) {
    Some(payload) => assert_eq(payload.tools, ["run_code"])
    None => fail("expected a ToolExemptions event")
  }
}

///|
test "a closed event system makes the exemption a silent no-op" {
  let system = @posoco.EventSystem()
  @devkit.events_system_register(system)
  let envelopes : Array[@posoco.EventEnvelope] = []
  match system.subscribe(fn(envelope) { envelopes.push(envelope) }) {
    Ok(_) => ()
    Err(_) => fail("subscribe on a fresh EventSystem failed")
  }
  assert_true(system.close() is Ok(_))
  let model = @tk.ScriptedModel([])
  let base = @runtime.PortRuntime(model=model as &@posoco.ModelPort)
  let _runtime = @posoco-ext-bunraku.BunrakuRuntime(
    fallback=base as &@runtime.Runtime,
  )
  assert_eq(envelopes.length(), 0)
}
