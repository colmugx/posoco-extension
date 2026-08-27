///|
/// Recording UiPort fake: captures every render intent for post-hoc
/// assertions. Services no interactive requests.
priv struct RecordingUi {
  renders : Array[@posoco.UiRender]
}

///|
fn RecordingUi::RecordingUi() -> RecordingUi {
  { renders: [] }
}

///|
fn RecordingUi::last(self : RecordingUi) -> @posoco.UiRender {
  match self.renders.last() {
    Some(render) => render
    None => abort("expected at least one render intent")
  }
}

///|
fn key_value_pairs(render : @posoco.UiRender) -> Array[(String, String)] {
  match render.body {
    @posoco.UiBody::KeyValue(pairs) => pairs
    _ => abort("expected a KeyValue body")
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
fn new_bar() -> (StatusBar, RecordingUi) {
  let ui = RecordingUi()
  (StatusBar(ui as &@posoco.UiPort), ui)
}

///|
test "set_model renders model and effort through the status slot" {
  let (bar, ui) = new_bar()
  inspect(ui.renders.length(), content="0")
  bar.set_model("deepseek-v4-pro", effort=Some("high"))
  let render = ui.last()
  assert_eq(render.slot, @posoco.UiSlot::Status)
  assert_eq(render.key, "statusbar")
  debug_inspect(
    key_value_pairs(render),
    content=(
      #|[
      #|  ("model", "deepseek-v4-pro"),
      #|  ("effort", "high"),
      #|  ("turn", "0"),
      #|  ("tools", "0"),
      #|  ("tok", "0↑ 0↓"),
      #|  ("session", "—"),
      #|]
    ),
  )
}

///|
test "effort segment is skipped when the model has no effort selection" {
  let (bar, ui) = new_bar()
  bar.set_model("deepseek-v4-flash", effort=None)
  let pairs = key_value_pairs(ui.last())
  assert_false(pairs.any(pair => pair.0 == "effort"))
  debug_inspect(
    pairs,
    content=(
      #|[
      #|  ("model", "deepseek-v4-flash"),
      #|  ("turn", "0"),
      #|  ("tools", "0"),
      #|  ("tok", "0↑ 0↓"),
      #|  ("session", "—"),
      #|]
    ),
  )
}

///|
test "observer collects turn, tool, and token telemetry" {
  let (bar, ui) = new_bar()
  bar.on_event(@posoco.TurnEvent::TurnStarted)
  bar.on_event(
    @posoco.TurnEvent::ToolCallPending(@posoco.ToolCall::{
      call_id: @posoco.CallId::unchecked("tc_1"),
      name: @posoco.ToolName::unchecked("read"),
      arguments: Json::null(),
    }),
  )
  bar.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=@posoco.tk_user_msg("hi"),
      usage=Some(@posoco.Usage::{
        input_tokens: Some(10),
        output_tokens: Some(4),
        total_tokens: None,
        cached_input_tokens: None,
        uncached_input_tokens: None,
      }),
    ),
  )
  bar.on_event(@posoco.TurnEvent::TurnCompleted)
  debug_inspect(
    key_value_pairs(ui.last()),
    content=(
      #|[
      #|  ("model", "—"),
      #|  ("turn", "1"),
      #|  ("tools", "1"),
      #|  ("tok", "10↑ 4↓"),
      #|  ("session", "—"),
      #|  ("lat", "0ms"),
      #|]
    ),
  )
}

///|
test "session redirect refreshes the session segment" {
  let (bar, ui) = new_bar()
  bar.on_event(
    @posoco.TurnEvent::SessionRedirect(
      from="s1",
      to="s2",
      messages_before=3,
      messages_after=1,
    ),
  )
  let pairs = key_value_pairs(ui.last())
  assert_true(pairs.any(pair => pair == ("session", "s2")))
  debug_inspect(
    pairs,
    content=(
      #|[
      #|  ("model", "—"),
      #|  ("turn", "0"),
      #|  ("tools", "0"),
      #|  ("tok", "0↑ 0↓"),
      #|  ("session", "s2"),
      #|]
    ),
  )
}

///|
test "latency segment appears only after the host pushes it" {
  let (bar, ui) = new_bar()
  bar.set_model("deepseek-v4-pro", effort=Some("high"))
  assert_false(key_value_pairs(ui.last()).any(pair => pair.0 == "lat"))
  bar.set_latency(830)
  let pairs = key_value_pairs(ui.last())
  assert_true(pairs.any(pair => pair == ("lat", "830ms")))
  debug_inspect(
    pairs,
    content=(
      #|[
      #|  ("model", "deepseek-v4-pro"),
      #|  ("effort", "high"),
      #|  ("turn", "0"),
      #|  ("tools", "0"),
      #|  ("tok", "0↑ 0↓"),
      #|  ("session", "—"),
      #|  ("lat", "830ms"),
      #|]
    ),
  )
}

// ------------------------------------------------------------ custom segments (bus + setters)

///|
test "host-pushed custom segment renders and clears" {
  let (bar, ui) = new_bar()
  bar.set_model("test-model", effort=None)
  bar.set_custom("hitrate", "62% (48/77)")
  let pairs = key_value_pairs(ui.last())
  // Built-in layout first, custom fact appended in first-arrival order.
  assert_true(pairs.contains(("model", "test-model")))
  assert_true(pairs.contains(("hitrate", "62% (48/77)")))
  bar.clear_custom("hitrate")
  let pairs = key_value_pairs(ui.last())
  assert_false(pairs.contains(("hitrate", "62% (48/77)")))
}

///|
test "bus publish on topic status updates custom segments once per event" {
  let bus = @devkit.EventBus()
  let ui = RecordingUi()
  let _bar = StatusBar(ui as &@posoco.UiPort, bus=Some(bus))
  let renders_before = ui.renders.length()
  bus.publish({
    source: "posoco_ext_scrum",
    topic: "status",
    data: Json::object({
      "sprint": Json::string("S12 day 4/10"),
      "hitrate": Json::string("62%"),
    }),
  })
  // One event → one render, even though two segments changed.
  assert_eq(ui.renders.length(), renders_before + 1)
  let pairs = key_value_pairs(ui.last())
  assert_true(pairs.contains(("sprint", "S12 day 4/10")))
  assert_true(pairs.contains(("hitrate", "62%")))
  // A second publish updates in place; a null drops the segment.
  bus.publish({
    source: "posoco_ext_scrum",
    topic: "status",
    data: Json::object({
      "hitrate": Json::string("71%"),
      "sprint": Json::null(),
    }),
  })
  let pairs = key_value_pairs(ui.last())
  assert_true(pairs.contains(("hitrate", "71%")))
  assert_false(pairs.contains(("sprint", "S12 day 4/10")))
}

///|
test "bus events the bar does not understand are ignored without a render" {
  let bus = @devkit.EventBus()
  let ui = RecordingUi()
  let bar = StatusBar(ui as &@posoco.UiPort, bus=Some(bus))
  let renders_before = ui.renders.length()
  // Unknown topic, non-object payload, non-string field value: all ignored.
  bus.publish({ source: "ext", topic: "other", data: Json::null() })
  bus.publish({ source: "ext", topic: "status", data: Json::string("text") })
  bus.publish({
    source: "ext",
    topic: "status",
    data: Json::object({ "bad": Json::boolean(true) }),
  })
  assert_eq(ui.renders.length(), renders_before)
  assert_eq(bar.custom_segments().length(), 0)
}

///|
test "a layout referencing a live custom segment places it explicitly" {
  let (bar, ui) = new_bar()
  bar.set_custom("hitrate", "62%")
  bar.items = ["hitrate", "model"]
  bar.render()
  let pairs = key_value_pairs(ui.last())
  assert_eq(pairs[0], ("hitrate", "62%"))
  assert_eq(pairs[1], ("model", "—"))
  // Not appended twice.
  assert_eq(pairs.length(), 2)
}

///|
test "tool count is session-cumulative across turns" {
  let (bar, ui) = new_bar()
  bar.on_event(@posoco.TurnEvent::TurnStarted)
  bar.on_event(@posoco.TurnEvent::ToolCallPending(tk_pending_call("c1")))
  bar.on_event(@posoco.TurnEvent::ToolCallPending(tk_pending_call("c2")))
  bar.on_event(@posoco.TurnEvent::TurnCompleted)
  // Turn 2 runs zero tools: the count must survive, not flash back to 0.
  bar.on_event(@posoco.TurnEvent::TurnStarted)
  let pairs = key_value_pairs(ui.last())
  assert_true(pairs.contains(("turn", "2")))
  assert_true(pairs.contains(("tools", "2")))
}

///|
fn tk_pending_call(id : String) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked(id),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(Map([])),
  }
}

///|
fn tk_round(input : Int, cached : Int?) -> @posoco.TurnEvent {
  @posoco.TurnEvent::ModelResponseReceived(
    message=@posoco.tk_user_msg("hi"),
    usage=Some(@posoco.Usage::{
      input_tokens: Some(input),
      output_tokens: Some(4),
      total_tokens: None,
      cached_input_tokens: cached,
      uncached_input_tokens: None,
    }),
  )
}

///|
test "cache segment summarizes the latest round's hit rate" {
  let (bar, ui) = new_bar()
  bar.on_event(@posoco.TurnEvent::TurnStarted)
  // No cached reporting yet: segment hidden.
  bar.on_event(tk_round(1200, None))
  assert_false(key_value_pairs(ui.last()).any(pair => pair.0 == "cache"))
  // Round reports 1000 of 1200 input tokens cached → 83%.
  bar.on_event(tk_round(1200, Some(1000)))
  assert_true(key_value_pairs(ui.last()).contains(("cache", "83%")))
  // Next round re-summarizes: 300 of 1200 → 25%.
  bar.on_event(tk_round(1200, Some(300)))
  assert_true(key_value_pairs(ui.last()).contains(("cache", "25%")))
  // A round whose provider reports no cached portion hides the segment
  // again (stale rates are never shown as current).
  bar.on_event(tk_round(900, None))
  assert_false(key_value_pairs(ui.last()).any(pair => pair.0 == "cache"))
}

///|
priv struct FakeClock {
  mut now_ms : Int64
}

///|
fn new_timed_bar() -> (StatusBar, RecordingUi, FakeClock) {
  let ui = RecordingUi()
  let clock = FakeClock::{ now_ms: 0 }
  let bar = StatusBar(ui as &@posoco.UiPort, clock=fn() { clock.now_ms })
  (bar, ui, clock)
}

///|
fn tk_delta(text : String) -> @posoco.TurnEvent {
  @posoco.TurnEvent::StreamChunkReceived(
    chunk=@posoco.StreamChunk::TextDelta(token=text),
  )
}

///|
test "per-round efficiency segments from the injected clock" {
  let (bar, ui, clock) = new_timed_bar()
  clock.now_ms = 1000
  bar.on_event(@posoco.TurnEvent::TurnStarted)
  clock.now_ms = 1500
  bar.on_event(tk_delta("he"))
  bar.on_event(tk_delta("llo")) // second delta: anchor unchanged
  clock.now_ms = 3500
  bar.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=@posoco.tk_user_msg("hi"),
      usage=Some(@posoco.Usage::{
        input_tokens: Some(10),
        output_tokens: Some(40),
        total_tokens: None,
        cached_input_tokens: None,
        uncached_input_tokens: None,
      }),
    ),
  )
  let pairs = key_value_pairs(ui.last())
  assert_true(pairs.contains(("ttft", "500ms")))
  assert_true(pairs.contains(("tps", "16.0/s")))
  assert_true(pairs.contains(("avg", "16.0/s")))
  // Round 2 of the same turn (tool loop): re-anchored at the previous
  // response; a fresh TTFT and tps, average now spans both rounds.
  clock.now_ms = 3600
  bar.on_event(tk_delta("x"))
  clock.now_ms = 4100
  bar.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=@posoco.tk_user_msg("hi"),
      usage=Some(@posoco.Usage::{
        input_tokens: Some(10),
        output_tokens: Some(10),
        total_tokens: None,
        cached_input_tokens: None,
        uncached_input_tokens: None,
      }),
    ),
  )
  let pairs = key_value_pairs(ui.last())
  assert_true(pairs.contains(("ttft", "100ms")))
  assert_true(pairs.contains(("tps", "16.7/s")))
  assert_true(pairs.contains(("avg", "16.3/s")))
  // Turn latency is self-computed from the same clock.
  clock.now_ms = 5000
  bar.on_event(@posoco.TurnEvent::TurnCompleted)
  let pairs = key_value_pairs(ui.last())
  assert_true(pairs.contains(("lat", "4000ms")))
}
