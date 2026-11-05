///|
/// Whitebox tests for the protocol: a fake capability (built through
/// `@events.Events::from_callbacks`, the documented framework hook) records
/// what a publisher sends and hands it to the subscribers, so the assertions
/// see exactly the envelopes production listeners see.

///|
/// A fake owner-bound capability: publications are delivered to the local
/// listeners stamped with this capability's namespace.
priv struct FakeCapability {
  owner : String
  listeners : Array[(@events.EventEnvelope) -> Unit]
}

///|
fn FakeCapability::FakeCapability(owner : String) -> FakeCapability {
  { owner, listeners: [], }
}

///|
fn FakeCapability::events(self : FakeCapability) -> @events.Events {
  @events.Events::from_callbacks(
    publish=fn(event, _scope) {
      let envelope = @events.EventEnvelope::EventEnvelope(
        namespace_=@events.Extension(self.owner),
        event~,
      )
      for listener in self.listeners.copy() {
        listener(envelope)
      }
      Ok(())
    },
    subscribe=fn(handler, _namespace_) {
      self.listeners.push(handler)
      Ok(@events.Subscription::from_cancel(fn() { () }))
    },
  )
}

///|
/// Collect every envelope published through `events` into `seen`.
fn record(events : @events.Events, seen : Array[@events.EventEnvelope]) -> Unit {
  match events.subscribe(fn(envelope) { seen.push(envelope) }) {
    Ok(_) => ()
    Err(_) => abort("subscribe on the fake capability failed")
  }
}

///|
test "register op mirrors the legacy status payload" {
  let cap = FakeCapability::FakeCapability("posoco_ext_llm")
  let events = cap.events()
  let seen : Array[@events.EventEnvelope] = []
  record(events, seen)
  ignore(
    events.publish(
      StatusChanged(
        Register(
          segment="model",
          label=Some("model"),
          priority=20,
          value=Some("claude:high"),
          color=Some("accent"),
        ),
      ),
    ),
  )
  assert_eq(seen.length(), 1)
  assert_eq(
    status_changed_of(seen[0]),
    Some(
      Register(
        segment="model",
        label=Some("model"),
        priority=20,
        value=Some("claude:high"),
        color=Some("accent"),
      ),
    ),
  )
  assert_eq(publisher_id(seen[0]), Some("posoco_ext_llm"))
}

///|
test "update and unregister ops keep their absent fields absent" {
  let cap = FakeCapability::FakeCapability("posoco_ext_openai")
  let events = cap.events()
  let seen : Array[@events.EventEnvelope] = []
  record(events, seen)
  ignore(events.publish(StatusChanged(Update(segment="cache", value="91%"))))
  ignore(events.publish(StatusChanged(Unregister(segment="cache"))))
  assert_eq(seen.length(), 2)
  assert_eq(
    status_changed_of(seen[0]),
    Some(Update(segment="cache", value="91%")),
  )
  assert_eq(status_changed_of(seen[1]), Some(Unregister(segment="cache")))
}

///|
test "a register without label, value or color decodes as None fields" {
  let cap = FakeCapability::FakeCapability("posoco_ext_stats")
  let events = cap.events()
  let seen : Array[@events.EventEnvelope] = []
  record(events, seen)
  ignore(
    events.publish(
      StatusChanged(
        Register(
          segment="turns",
          label=None,
          priority=0,
          value=None,
          color=None,
        ),
      ),
    ),
  )
  assert_eq(
    status_changed_of(seen[0]),
    Some(
      Register(segment="turns", label=None, priority=0, value=None, color=None),
    ),
  )
}

///|
test "tool exemptions carry the exact tool names" {
  let cap = FakeCapability::FakeCapability("posoco_ext_plan")
  let events = cap.events()
  let seen : Array[@events.EventEnvelope] = []
  record(events, seen)
  ignore(
    events.publish(ToolExemptions({ tools: ["plan_enter", "plan_exit"], })),
  )
  assert_eq(
    tool_exemptions_of(seen[0]),
    Some({ tools: ["plan_enter", "plan_exit"], }),
  )
  assert_eq(status_changed_of(seen[0]), None)
}

///|
test "model selection keeps a null effort as None" {
  let cap = FakeCapability::FakeCapability("posoco_ext_llm")
  let events = cap.events()
  let seen : Array[@events.EventEnvelope] = []
  record(events, seen)
  ignore(
    events.publish(
      ModelSelection({ slot_id: "anthropic/claude", effort: None, }),
    ),
  )
  ignore(
    events.publish(
      ModelSelection({ slot_id: "anthropic/claude", effort: Some("high"), }),
    ),
  )
  assert_eq(
    model_selection_of(seen[0]),
    Some({ slot_id: "anthropic/claude", effort: None, }),
  )
  assert_eq(
    model_selection_of(seen[1]),
    Some({ slot_id: "anthropic/claude", effort: Some("high"), }),
  )
  assert_eq(decision_selection_of(seen[1]), None)
}

///|
test "decision selection keeps availability and reason" {
  let cap = FakeCapability::FakeCapability("posoco_ext_llm")
  let events = cap.events()
  let seen : Array[@events.EventEnvelope] = []
  record(events, seen)
  ignore(
    events.publish(
      DecisionSelection({
        slot_id: "openai/gpt",
        available: true,
        reason: None,
      }),
    ),
  )
  ignore(
    events.publish(
      DecisionSelection({
        slot_id: "",
        available: false,
        reason: Some("no decision slot selected"),
      }),
    ),
  )
  assert_eq(
    decision_selection_of(seen[0]),
    Some({ slot_id: "openai/gpt", available: true, reason: None, }),
  )
  assert_eq(
    decision_selection_of(seen[1]),
    Some({
      slot_id: "",
      available: false,
      reason: Some("no decision slot selected"),
    }),
  )
}

///|
test "provider status names the active provider" {
  let cap = FakeCapability::FakeCapability("posoco_ext_llm")
  let events = cap.events()
  let seen : Array[@events.EventEnvelope] = []
  record(events, seen)
  ignore(events.publish(ProviderStatus({ provider_id: "openai", })))
  assert_eq(provider_status_of(seen[0]), Some({ provider_id: "openai", }))
  assert_eq(profiles_activated_of(seen[0]), None)
}

///|
test "profiles activation carries the id and members" {
  let cap = FakeCapability::FakeCapability("posoco_ext_profiles")
  let events = cap.events()
  let seen : Array[@events.EventEnvelope] = []
  record(events, seen)
  ignore(
    events.publish(
      ProfilesActivated({ id: "rust", members: ["posoco_ext_astgrep"], }),
    ),
  )
  assert_eq(
    profiles_activated_of(seen[0]),
    Some({ id: "rust", members: ["posoco_ext_astgrep"], }),
  )
  assert_eq(provider_status_of(seen[0]), None)
}

///|
test "core notifications carry no protocol payload and no publisher id" {
  let envelope = @events.EventEnvelope::EventEnvelope(
    namespace_=@events.Posoco,
    event=@events.Core(@types.TurnStarted),
  )
  assert_eq(publisher_id(envelope), None)
  assert_eq(status_changed_of(envelope), None)
  assert_eq(tool_exemptions_of(envelope), None)
  assert_eq(model_selection_of(envelope), None)
  assert_eq(decision_selection_of(envelope), None)
  assert_eq(provider_status_of(envelope), None)
  assert_eq(profiles_activated_of(envelope), None)
}

///|
test "a wildcard branch keeps the open event type exhaustive" {
  let cap = FakeCapability::FakeCapability("posoco_ext_bash")
  let events = cap.events()
  let seen : Array[@events.EventEnvelope] = []
  record(events, seen)
  ignore(events.publish(StatusChanged(Unregister(segment="bg"))))
  let described = match seen[0].event {
    StatusChanged(Unregister(segment~)) => "released \{segment}"
    StatusChanged(_) => "status"
    _ => "another protocol"
  }
  assert_eq(described, "released bg")
}
