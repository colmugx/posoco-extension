///|
/// Recording UiPort fake: captures every render intent for post-hoc
/// assertions. Services no interactive requests.
priv struct RecordingUi {
  renders : Array[@posoco.UiRender]
}

///|
fn RecordingUi::new() -> RecordingUi {
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
  let ui = RecordingUi::new()
  (StatusBar::new(ui as &@posoco.UiPort), ui)
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
