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
/// A bridge subscribed to a real devkit bus and composed against a
/// RecordingUi — the full wiring the agent composer would build. Publishes
/// on the bus exercise the cross-package protocol end to end.
fn new_composed_bar() -> (StatusBar, RecordingUi, @devkit.EventBus) raise @posoco.CompositionError {
  let ui = RecordingUi()
  let bus = @devkit.EventBus()
  let bar = StatusBar(bus=Some(bus))
  let model = @posoco.ScriptedModel([])
  bar.on_compose(
    @posoco.tk_view(
      requires=[@posoco.Capability::Ui],
      model=model as &@posoco.ModelPort,
      ui=ui as &@posoco.UiPort,
    ),
  )
  (bar, ui, bus)
}

///|
test "register with a value renders the segment through the status slot" {
  let (_bar, ui, bus) = new_composed_bar()
  @devkit.publish_status_register(
    bus,
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
test "update on an unknown segment auto-registers it" {
  let (bar, ui, bus) = new_composed_bar()
  @devkit.publish_status_update(
    bus,
    source="posoco_ext_stats",
    segment="tps",
    value="42.0/s",
  )
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
  let (_bar, ui, bus) = new_composed_bar()
  @devkit.publish_status_register(
    bus,
    source="posoco_ext_plan",
    segment="plan",
    priority=10,
    value="Plan",
  )
  assert_eq(ui.renders.length(), 1)
  @devkit.publish_status_unregister(
    bus,
    source="posoco_ext_plan",
    segment="plan",
  )
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
  let (bar, ui, bus) = new_composed_bar()
  @devkit.publish_status_register(
    bus,
    source="posoco_ext_llm",
    segment="model",
    priority=20,
    value="deepseek-v4-pro",
  )
  assert_eq(ui.renders.length(), 1)
  // Foreign update: ignored — no state change, no render.
  @devkit.publish_status_update(
    bus,
    source="posoco_ext_imposter",
    segment="model",
    value="hijacked",
  )
  assert_eq(ui.renders.length(), 1)
  // Foreign unregister: ignored.
  @devkit.publish_status_unregister(
    bus,
    source="posoco_ext_imposter",
    segment="model",
  )
  assert_eq(ui.renders.length(), 1)
  // Foreign register: ignored.
  @devkit.publish_status_register(
    bus,
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
  let (bar, _ui, bus) = new_composed_bar()
  @devkit.publish_status_register(
    bus,
    source="ext",
    segment="first",
    priority=50,
    value="1",
  )
  @devkit.publish_status_register(
    bus,
    source="ext",
    segment="second",
    priority=50,
    value="2",
  )
  // Same priority: registration order so far.
  debug_inspect(
    bar.segments().map(fn(info) { info.segment }),
    content=(
      #|["first", "second"]
    ),
  )
  // Overwriting "first" must not move it behind "second".
  @devkit.publish_status_register(
    bus,
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
  let (bar, ui, bus) = new_composed_bar()
  @devkit.publish_status_register(
    bus,
    source="ext",
    segment="c",
    priority=30,
    value="C",
  )
  @devkit.publish_status_register(
    bus,
    source="ext",
    segment="a",
    priority=10,
    value="A",
  )
  @devkit.publish_status_register(
    bus,
    source="ext",
    segment="d",
    priority=30,
    value="D",
  )
  @devkit.publish_status_register(
    bus,
    source="ext",
    segment="b",
    priority=20,
    value="B",
  )
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
  let (bar, ui, bus) = new_composed_bar()
  @devkit.publish_status_register(
    bus,
    source="posoco_ext_plan",
    segment="plan",
    priority=10,
  )
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
  @devkit.publish_status_update(
    bus,
    source="posoco_ext_plan",
    segment="plan",
    value="Plan",
  )
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
test "direct set_segment matches the bus path" {
  let bus_bar = StatusBar(bus=None)
  let bus_ui = RecordingUi()
  let bus = @devkit.EventBus()
  let wired = StatusBar(bus=Some(bus))
  let model = @posoco.ScriptedModel([])
  wired.on_compose(
    @posoco.tk_view(
      requires=[@posoco.Capability::Ui],
      model=model as &@posoco.ModelPort,
      ui=bus_ui as &@posoco.UiPort,
    ),
  )
  let direct_ui = RecordingUi()
  let direct = StatusBar()
  direct.on_compose(
    @posoco.tk_view(
      requires=[@posoco.Capability::Ui],
      model=model as &@posoco.ModelPort,
      ui=direct_ui as &@posoco.UiPort,
    ),
  )
  // Same op sequence, same order, through both doors: updates
  // auto-register at priority 0 on either path.
  @devkit.publish_status_update(bus, source="llm", segment="model", value="m1")
  direct.set_segment(source="llm", segment="model", value="m1")
  @devkit.publish_status_update(
    bus,
    source="llm",
    segment="session",
    value="s1",
  )
  direct.set_segment(source="llm", segment="session", value="s1")
  assert_eq(wired.segments(), direct.segments())
  assert_same_entries(bar_entries(bus_ui.last()), bar_entries(direct_ui.last()))
  // The clear path lands in the same state too.
  @devkit.publish_status_unregister(bus, source="llm", segment="model")
  direct.clear_segment(source="llm", segment="model")
  assert_eq(wired.segments(), direct.segments())
  assert_same_entries(bar_entries(bus_ui.last()), bar_entries(direct_ui.last()))
  assert_eq(bus_bar.segments().length(), 0)
}

///|
test "malformed bus events render nothing" {
  let (_bar, ui, bus) = new_composed_bar()
  bus.publish({ source: "ext", topic: "other", data: Json::null(), })
  bus.publish({ source: "ext", topic: "status", data: Json::string("text"), })
  bus.publish({
    source: "ext",
    topic: "status",
    data: Json::object({ "op": Json::string("nonsense") }),
  })
  bus.publish({
    source: "ext",
    topic: "status",
    data: Json::object({
      "op": Json::string("update"),
      "segment": Json::string("x"),
    }),
  })
  bus.publish({
    source: "ext",
    topic: "status",
    data: Json::object({
      "op": Json::string("update"),
      "segment": Json::string("x"),
      "value": Json::boolean(true),
    }),
  })
  assert_eq(ui.renders.length(), 0)
}

///|
test "renders start only after the composed UI arrives" {
  let ui = RecordingUi()
  let bus = @devkit.EventBus()
  let bar = StatusBar(bus=Some(bus))
  @devkit.publish_status_register(
    bus,
    source="ext",
    segment="model",
    priority=20,
    value="m",
  )
  // Applied (registry updated) but silent: no UI to render through.
  assert_eq(ui.renders.length(), 0)
  assert_eq(bar.segments().length(), 1)
  let model = @posoco.ScriptedModel([])
  bar.on_compose(
    @posoco.tk_view(
      requires=[@posoco.Capability::Ui],
      model=model as &@posoco.ModelPort,
      ui=ui as &@posoco.UiPort,
    ),
  )
  @devkit.publish_status_update(bus, source="ext", segment="model", value="m2")
  // The first render carries the full current registry, not just the delta.
  assert_eq(ui.renders.length(), 1)
  debug_inspect(
    bar_entries(ui.last()),
    content=(
      #|[{ key: "model", value: "m2", color: None }]
    ),
  )
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
  let (bar, ui, bus) = new_composed_bar()
  @devkit.publish_status_register(
    bus,
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
  let (bar, ui, bus) = new_composed_bar()
  @devkit.publish_status_register(
    bus,
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
  let (bar, ui, bus) = new_composed_bar()
  @devkit.publish_status_register(
    bus,
    source="ext",
    segment="plan",
    priority=10,
    value="Plan",
    color="accent",
  )
  assert_eq(bar.segments()[0].color, Some("accent"))
  @devkit.publish_status_register(
    bus,
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
  @devkit.publish_status_register(
    bus,
    source="ext",
    segment="plan",
    priority=10,
    value="Plan",
  )
  assert_eq(bar.segments()[0].color, None)
}
