///|
/// StatusBar: a data-driven status line extension.
///
/// The bar owns a small fact set (model, effort, turn counters, token usage,
/// session, latency), projects it into an ordered list of named segments,
/// and pushes the result through `UiPort::render` as a `UiSlot::Status`
/// intent with the conventional key `"statusbar"`. The host decides where
/// (and whether) to mount it — bottom footer today, top bar tomorrow.

///|
/// Segment ids the bar knows how to render, in default order.
pub fn available_segments() -> Array[String] {
  ["model", "effort", "turn", "tools", "tok", "session", "lat"]
}

///|
/// Default layout: every known segment, in registry order.
pub fn default_items() -> Array[String] {
  available_segments()
}

///|
/// Mutable fact set. All writes go through small methods on `StatusBar`;
/// every write triggers exactly one re-render. Opaque outside the package.
pub struct StatusBarState {
  mut model : String?
  mut effort : String?
  mut turn_count : Int
  mut tools_this_turn : Int
  mut tokens_in : Int
  mut tokens_out : Int
  mut session_id : String?
  mut latency_ms : Int?
}

///|
fn StatusBarState::new() -> StatusBarState {
  {
    model: None,
    effort: None,
    turn_count: 0,
    tools_this_turn: 0,
    tokens_in: 0,
    tokens_out: 0,
    session_id: None,
    latency_ms: None,
  }
}

///|
/// Pure projection: map a segment id to its display value. `None` skips the
/// segment — no data yet (latency before the first completed turn) or not
/// applicable (effort on a model without effort selection).
fn segment_value(id : String, state : StatusBarState) -> String? {
  match id {
    "model" =>
      match state.model {
        Some(label) => Some(label)
        None => Some("—")
      }
    "effort" => state.effort
    "turn" => Some(state.turn_count.to_string())
    "tools" => Some(state.tools_this_turn.to_string())
    "tok" =>
      Some(
        state.tokens_in.to_string() +
        "↑ " +
        state.tokens_out.to_string() +
        "↓",
      )
    "session" =>
      match state.session_id {
        Some(id) => Some(id)
        None => Some("—")
      }
    "lat" =>
      match state.latency_ms {
        Some(ms) => Some(ms.to_string() + "ms")
        None => None
      }
    _ => None
  }
}

///|
/// The status bar extension. One struct, three port views: `Observer`
/// (self-collects turn/token telemetry), `CommandPort` (`/statusbar`
/// customization), and `Extension` (self-reporting manifest).
pub struct StatusBar {
  ui : &@posoco.UiPort
  state : StatusBarState
  mut items : Array[String]
}

///|
/// Compose a status bar over the host's `UiPort`. `items` selects and orders
/// segments; unknown ids are ignored at render time (the `/statusbar`
/// command validates strictly instead).
pub fn StatusBar::new(
  ui : &@posoco.UiPort,
  items? : Array[String] = default_items(),
) -> StatusBar {
  { ui, state: StatusBarState::new(), items }
}

///|
/// Current segment layout.
pub fn StatusBar::items(self : StatusBar) -> Array[String] {
  self.items.copy()
}

///|
/// Project state through the layout and push one render intent. Segment
/// projection is pure; the `UiPort::render` call is the only effect.
fn StatusBar::render(self : StatusBar) -> Unit {
  let pairs : Array[(String, String)] = []
  for item in self.items {
    match segment_value(item, self.state) {
      Some(value) => pairs.push((item, value))
      None => ()
    }
  }
  self.ui.render(@posoco.UiRender::{
    slot: @posoco.UiSlot::Status,
    key: "statusbar",
    title: None,
    body: @posoco.UiBody::KeyValue(pairs),
    ttl_ms: None,
  })
}

///|
/// Host-pushed fact: the active model label and its reasoning effort.
/// `effort=None` means the model has no effort selection; the segment is
/// skipped rather than rendered as a placeholder.
pub fn StatusBar::set_model(
  self : StatusBar,
  label : String,
  effort~ : String?,
) -> Unit {
  self.state.model = Some(label)
  self.state.effort = effort
  self.render()
}

///|
/// Host-pushed fact: the active session id.
pub fn StatusBar::set_session(self : StatusBar, id : String) -> Unit {
  self.state.session_id = Some(id)
  self.render()
}

///|
/// Host-pushed fact: wall-clock latency of the last completed turn.
pub fn StatusBar::set_latency(self : StatusBar, ms : Int) -> Unit {
  self.state.latency_ms = Some(ms)
  self.render()
}

///|
/// Machine-readable layout report for the `/statusbar` command.
fn StatusBar::layout_json(self : StatusBar) -> Json {
  Json::object(
    Map::from_array([
      ("items", Json::array(self.items.map(item => Json::string(item)))),
      (
        "available",
        Json::array(available_segments().map(item => Json::string(item))),
      ),
      ("defaults", Json::array(default_items().map(item => Json::string(item)))),
    ]),
  )
}
