///|
/// Recording UiPort fake: captures every render intent for post-hoc
/// assertions. Services no interactive requests.
priv struct RecordingUi {
  renders : Array[@posoco.UiRender]
}

///|
fn RecordingUi::RecordingUi() -> RecordingUi {
  { renders: [], }
}

///|
fn RecordingUi::last(self : RecordingUi) -> @posoco.UiRender {
  match self.renders.last() {
    Some(render) => render
    None => abort("expected at least one render intent")
  }
}

///|
fn bar_entries(render : @posoco.UiRender) -> Array[@posoco.UiEntry] {
  match render.body {
    @posoco.UiBody::Entries(entries) => entries
    _ => abort("expected an Entries body")
  }
}

///|
/// UiEntry does not derive Eq, so two Entries bodies are compared
/// field-wise.
fn assert_same_entries(
  a : Array[@posoco.UiEntry],
  b : Array[@posoco.UiEntry],
) -> Unit raise {
  assert_eq(a.length(), b.length())
  for i in 0..<a.length() {
    assert_eq(a[i].key, b[i].key)
    assert_eq(a[i].value, b[i].value)
    assert_eq(a[i].color, b[i].color)
  }
}

///|
impl @posoco.UiPort for RecordingUi with fn ui_descriptor(_self : RecordingUi) -> @posoco.UiDescriptor {
  @posoco.UiDescriptor::empty()
}

///|
impl @posoco.UiPort for RecordingUi with fn render(
  self : RecordingUi,
  intent : @posoco.UiRender,
) -> Unit {
  self.renders.push(intent)
}

///|
impl @posoco.UiPort for RecordingUi with fn request(
  _self : RecordingUi,
  _req : @posoco.UiRequest,
) -> @posoco.UiResponse {
  raise @posoco.UiError::Unsupported(
    detail="RecordingUi does not service requests",
  )
}

///|
/// Test-side status channel: one fresh `@posoco.EventSystem`, registered as
/// the process default exactly as the host assembly does, so the bar under
/// test and the publishes below travel the production channel. Each publish
/// mints a capability for its `source`, so the envelope carries the publisher
/// identity the ownership rule filters on (`@kit_events.publisher_id`).
priv struct Channel {
  system : @posoco.EventSystem
}

///|
fn Channel::Channel() -> Channel {
  let system = @posoco.EventSystem()
  @devkit.events_system_register(system)
  { system, }
}

///|
fn Channel::publish(
  self : Channel,
  source~ : String,
  op~ : @kit_events.StatusOp,
) -> Unit {
  let events = match self.system.publisher(owner=source) {
    Ok(events) => events
    Err(_) => abort("minting a publisher capability failed")
  }
  ignore(events.publish(@kit_events.StatusChanged(op)))
}

///|
/// Publish a register op on behalf of `source`, the way a peer extension
/// does.
fn Channel::register(
  self : Channel,
  source~ : String,
  segment~ : String,
  label? : String,
  priority~ : Int32 = 0,
  value? : String,
  color? : String,
) -> Unit {
  self.publish(
    source~,
    op=@kit_events.Register(segment~, label~, priority~, value~, color~),
  )
}

///|
/// Publish an update op on behalf of `source`.
fn Channel::update(
  self : Channel,
  source~ : String,
  segment~ : String,
  value~ : String,
) -> Unit {
  self.publish(source~, op=@kit_events.Update(segment~, value~))
}

///|
/// Publish an unregister op on behalf of `source`.
fn Channel::unregister(
  self : Channel,
  source~ : String,
  segment~ : String,
) -> Unit {
  self.publish(source~, op=@kit_events.Unregister(segment~))
}

///|
/// Deliver the composed UI to a bar the way composition does.
fn compose_bar(
  bar : StatusBar,
  ui : RecordingUi,
) -> Unit raise @posoco.CompositionError {
  let model = @tk.ScriptedModel([])
  bar.on_compose(
    @tk.tk_view(
      requires=[@posoco.Capability::Ui],
      model=model as &@posoco.ModelPort,
      ui=ui as &@posoco.UiPort,
    ),
  )
}

///|
/// A bridge subscribed to a real event system and composed against a
/// RecordingUi — the full wiring the agent composer would build. Publishes on
/// that system exercise the cross-package protocol end to end.
fn new_composed_bar() -> (StatusBar, RecordingUi, Channel) raise @posoco.CompositionError {
  let ui = RecordingUi()
  let channel = Channel::Channel()
  let bar = StatusBar(events=Some(channel.system))
  compose_bar(bar, ui)
  (bar, ui, channel)
}

///|
test "register with a value renders the segment through the status slot" {
  let (_bar, ui, channel) = new_composed_bar()
  channel.register(
    source="posoco_ext_plan",
    segment="plan",
    label="Plan",
    priority=10,
    value="Plan",
  )
  assert_eq(ui.renders.length(), 1)
  let render = ui.last()
  assert_eq(render.slot, @posoco.UiSlot::Status)
  assert_eq(render.key, "statusbar")
  assert_eq(render.title, None)
  assert_eq(render.ttl_ms, None)
  debug_inspect(
    bar_entries(render),
    content=(
      #|[{ key: "plan", value: "Plan", color: None }]
    ),
  )
}

///|
test "compose with no announced segments stays silent" {
  let ui = RecordingUi()
  let channel = Channel::Channel()
  let bar = StatusBar(events=Some(channel.system))
  compose_bar(bar, ui)
  assert_eq(ui.renders.length(), 0)
}

///|
test "update on an unknown segment auto-registers it" {
  let (bar, ui, channel) = new_composed_bar()
  channel.update(source="posoco_ext_stats", segment="tps", value="42.0/s")
  assert_eq(ui.renders.length(), 1)
  let entries = bar_entries(ui.last())
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].key, "tps")
  assert_eq(entries[0].value, "42.0/s")
  assert_eq(entries[0].color, None)
  assert_eq(bar.segments(), [
    {
      segment: "tps",
      owner: "posoco_ext_stats",
      label: None,
      priority: 0,
      value: Some("42.0/s"),
      color: None,
    },
  ])
}

///|
test "unregister renders the emptied bar" {
  let (_bar, ui, channel) = new_composed_bar()
  channel.register(
    source="posoco_ext_plan",
    segment="plan",
    priority=10,
    value="Plan",
  )
  assert_eq(ui.renders.length(), 1)
  channel.unregister(source="posoco_ext_plan", segment="plan")
  // The applied change that empties the bar still renders: an empty
  // Entries body tells the host to clear the line.
  assert_eq(ui.renders.length(), 2)
  debug_inspect(
    bar_entries(ui.last()),
    content=(
      #|[]
    ),
  )
}

///|
test "ownership: a second source cannot update, clear, or re-register" {
  let (bar, ui, channel) = new_composed_bar()
  channel.register(
    source="posoco_ext_llm",
    segment="model",
    priority=20,
    value="deepseek-v4-pro",
  )
  assert_eq(ui.renders.length(), 1)
  // Foreign update: ignored — no state change, no render.
  channel.update(
    source="posoco_ext_imposter",
    segment="model",
    value="hijacked",
  )
  assert_eq(ui.renders.length(), 1)
  // Foreign unregister: ignored.
  channel.unregister(source="posoco_ext_imposter", segment="model")
  assert_eq(ui.renders.length(), 1)
  // Foreign register: ignored.
  channel.register(
    source="posoco_ext_imposter",
    segment="model",
    priority=99,
    value="stolen",
  )
  assert_eq(ui.renders.length(), 1)
  assert_eq(bar.segments(), [
    {
      segment: "model",
      owner: "posoco_ext_llm",
      label: None,
      priority: 20,
      value: Some("deepseek-v4-pro"),
      color: None,
    },
  ])
  // The direct paths enforce the same rule.
  bar.set_segment(
    source="posoco_ext_imposter",
    segment="model",
    value="hijacked",
  )
  assert_eq(ui.renders.length(), 1)
  bar.clear_segment(source="posoco_ext_imposter", segment="model")
  assert_eq(ui.renders.length(), 1)
  assert_eq(bar.segments().length(), 1)
}

///|
test "owner re-register overwrites metadata but keeps first_seen order" {
  let (bar, _ui, channel) = new_composed_bar()
  channel.register(source="ext", segment="first", priority=50, value="1")
  channel.register(source="ext", segment="second", priority=50, value="2")
  // Same priority: registration order so far.
  debug_inspect(
    bar.segments().map(fn(info) { info.segment }),
    content=(
      #|["first", "second"]
    ),
  )
  // Overwriting "first" must not move it behind "second".
  channel.register(
    source="ext",
    segment="first",
    label="Renamed",
    priority=50,
    value="1b",
  )
  assert_eq(bar.segments(), [
    {
      segment: "first",
      owner: "ext",
      label: Some("Renamed"),
      priority: 50,
      value: Some("1b"),
      color: None,
    },
    {
      segment: "second",
      owner: "ext",
      label: None,
      priority: 50,
      value: Some("2"),
      color: None,
    },
  ])
}

///|
test "ordering is priority ascending then first-seen ascending" {
  let (bar, ui, channel) = new_composed_bar()
  channel.register(source="ext", segment="c", priority=30, value="C")
  channel.register(source="ext", segment="a", priority=10, value="A")
  channel.register(source="ext", segment="d", priority=30, value="D")
  channel.register(source="ext", segment="b", priority=20, value="B")
  debug_inspect(
    bar.segments().map(fn(info) { info.segment }),
    content=(
      #|["a", "b", "c", "d"]
    ),
  )
  debug_inspect(
    bar_entries(ui.last()),
    content=(
      #|[
      #|  { key: "a", value: "A", color: None },
      #|  { key: "b", value: "B", color: None },
      #|  { key: "c", value: "C", color: None },
      #|  { key: "d", value: "D", color: None },
      #|]
    ),
  )
}

///|
test "valueless segments render nothing but stay listed" {
  let (bar, ui, channel) = new_composed_bar()
  channel.register(source="posoco_ext_plan", segment="plan", priority=10)
  // Applied registration, so one render fires — with the segment absent.
  assert_eq(ui.renders.length(), 1)
  debug_inspect(
    bar_entries(ui.last()),
    content=(
      #|[]
    ),
  )
  // Known to the registry and the listing, just not visible.
  assert_eq(bar.segments().length(), 1)
  assert_eq(bar.segments()[0].value, None)
  // A later update makes it visible, keeping priority and owner.
  channel.update(source="posoco_ext_plan", segment="plan", value="Plan")
  debug_inspect(
    bar_entries(ui.last()),
    content=(
      #|[{ key: "plan", value: "Plan", color: None }]
    ),
  )
  assert_eq(bar.segments()[0].priority, 10)
  assert_eq(bar.segments()[0].owner, "posoco_ext_plan")
}

///|
test "direct set_segment matches the event path" {
  // The direct bar listens on a system nobody publishes to, so only its own
  // direct calls move its registry.
  let idle = @posoco.EventSystem()
  let wired_ui = RecordingUi()
  let channel = Channel::Channel()
  let wired = StatusBar(events=Some(channel.system))
  compose_bar(wired, wired_ui)
  let direct_ui = RecordingUi()
  let direct = StatusBar(events=Some(idle))
  compose_bar(direct, direct_ui)
  // Same op sequence, same order, through both doors: updates
  // auto-register at priority 0 on either path.
  channel.update(source="llm", segment="model", value="m1")
  direct.set_segment(source="llm", segment="model", value="m1")
  channel.update(source="llm", segment="session", value="s1")
  direct.set_segment(source="llm", segment="session", value="s1")
  assert_eq(wired.segments(), direct.segments())
  assert_same_entries(
    bar_entries(wired_ui.last()),
    bar_entries(direct_ui.last()),
  )
  // The clear path lands in the same state too.
  channel.unregister(source="llm", segment="model")
  direct.clear_segment(source="llm", segment="model")
  assert_eq(wired.segments(), direct.segments())
  assert_same_entries(
    bar_entries(wired_ui.last()),
    bar_entries(direct_ui.last()),
  )
}

///|
test "non-status and core events render nothing" {
  let (bar, ui, channel) = new_composed_bar()
  // The channel carries every protocol payload: only `StatusChanged` ops move
  // the registry.
  let events = match channel.system.publisher(owner="posoco_ext_plan") {
    Ok(events) => events
    Err(_) => abort("minting a publisher capability failed")
  }
  ignore(events.publish(@kit_events.ToolExemptions({ tools: ["plan_enter"], })))
  ignore(events.publish(@kit_events.ProviderStatus({ provider_id: "openai", })))
  // Core notifications carry no publisher identity, so even a status-shaped
  // payload delivered by the core namespace is ignored.
  bar.on_status_event(
    @events.EventEnvelope(
      namespace_=@events.Posoco,
      event=@kit_events.StatusChanged(
        @kit_events.Update(segment="core", value="x"),
      ),
    ),
  )
  assert_eq(ui.renders.length(), 0)
  assert_eq(bar.segments().length(), 0)
}

///|
test "segments announced before the UI project at compose" {
  let ui = RecordingUi()
  let channel = Channel::Channel()
  let bar = StatusBar(events=Some(channel.system))
  channel.register(source="ext", segment="model", priority=20, value="m")
  // Applied (registry updated) but silent: no UI to render through.
  assert_eq(ui.renders.length(), 0)
  assert_eq(bar.segments().length(), 1)
  compose_bar(bar, ui)
  // UI arrival projects the announced backlog immediately: resident
  // segments are visible from the start, not after their next change.
  assert_eq(ui.renders.length(), 1)
  debug_inspect(
    bar_entries(ui.last()),
    content=(
      #|[{ key: "model", value: "m", color: None }]
    ),
  )
  channel.update(source="ext", segment="model", value="m2")
  // Later changes re-render the full current registry, not just the delta.
  assert_eq(ui.renders.length(), 2)
  debug_inspect(
    bar_entries(ui.last()),
    content=(
      #|[{ key: "model", value: "m2", color: None }]
    ),
  )
}

///|
test "a bar with no explicit system listens on the process default one" {
  // The host assembly registers its system before constructing extensions, so
  // a bar built without one still reaches the session channel.
  let ui = RecordingUi()
  let channel = Channel::Channel()
  let bar = StatusBar()
  compose_bar(bar, ui)
  channel.register(source="ext", segment="plan", priority=10, value="P")
  assert_eq(ui.renders.length(), 1)
  debug_inspect(
    bar_entries(ui.last()),
    content=(
      #|[{ key: "plan", value: "P", color: None }]
    ),
  )
}

///|
async test "shutdown detaches the listener" {
  let (bar, ui, channel) = new_composed_bar()
  channel.register(source="ext", segment="plan", priority=10, value="P")
  assert_eq(ui.renders.length(), 1)
  bar.on_shutdown()
  channel.register(source="ext", segment="plan", priority=10, value="P2")
  // Cancelled: later ops on the same system reach nobody.
  assert_eq(ui.renders.length(), 1)
}

///|
test "manifest declares the Ui requirement, lifecycle, and command" {
  let bar = StatusBar()
  let manifest = bar.manifest()
  assert_eq(manifest.id, "posoco_ext_statusbar")
  assert_eq(manifest.requires, [@posoco.Capability::Ui])
  assert_eq(manifest.observers.length(), 0)
  assert_eq(manifest.lifecycle.length(), 1)
  assert_eq(manifest.commands.length(), 1)
  assert_eq(manifest.ui.length(), 0)
  assert_eq(bar.extension_id(), "posoco_ext_statusbar")
}

///|
async test "register with a color role round-trips to a colored entry" {
  let (bar, ui, channel) = new_composed_bar()
  channel.register(
    source="posoco_ext_plan",
    segment="plan",
    priority=10,
    value="Plan",
    color="accent",
  )
  assert_eq(ui.renders.length(), 1)
  let entries = bar_entries(ui.last())
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].key, "plan")
  assert_eq(entries[0].value, "Plan")
  assert_eq(entries[0].color, Some("accent"))
  assert_eq(bar.segments()[0].color, Some("accent"))
  // /statusbar surfaces the role in both the line and the JSON payload.
  let outcome = bar.invoke("statusbar", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      inspect(
        feedback,
        content=(
          #|statusbar segments: 1
          #|plan | posoco_ext_plan | p10 | accent | Plan
        ),
      )
      match structured {
        Some(json) =>
          json_inspect(json, content=[
            {
              "segment": "plan",
              "owner": "posoco_ext_plan",
              "priority": 10,
              "color": "accent",
              "value": "Plan",
            },
          ])
        None => fail("expected a structured listing payload")
      }
    }
    _ => fail("expected success")
  }
}

///|
test "unknown color role decolors instead of failing the register" {
  let (bar, ui, channel) = new_composed_bar()
  channel.register(
    source="ext",
    segment="mood",
    priority=5,
    value="sparkling",
    color="sparkly",
  )
  // The register still applies and renders — just without a color.
  assert_eq(ui.renders.length(), 1)
  let entries = bar_entries(ui.last())
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].key, "mood")
  assert_eq(entries[0].value, "sparkling")
  assert_eq(entries[0].color, None)
  assert_eq(bar.segments()[0].color, None)
}

///|
test "owner re-register overwrites the color role" {
  let (bar, ui, channel) = new_composed_bar()
  channel.register(
    source="ext",
    segment="plan",
    priority=10,
    value="Plan",
    color="accent",
  )
  assert_eq(bar.segments()[0].color, Some("accent"))
  channel.register(
    source="ext",
    segment="plan",
    priority=10,
    value="Plan",
    color="warning",
  )
  assert_eq(ui.renders.length(), 2)
  assert_eq(bar.segments()[0].color, Some("warning"))
  // Color is register metadata like label: a re-register without one
  // clears it.
  channel.register(source="ext", segment="plan", priority=10, value="Plan")
  assert_eq(bar.segments()[0].color, None)
}
