///|
/// StatusBar: a data-driven status line extension.
///
/// The bar owns a small fact set (model, effort, session-cumulative turn and
/// tool-call counters, per-turn token usage, per-round cache hit rate and
/// token-efficiency timings — TTFT, tokens/s, session average —, session,
/// latency, plus any number of peer-published custom segments),
/// projects it into an ordered list of named segments, and pushes the
/// result through `UiPort::render` as a `UiSlot::Status` intent with the
/// conventional key `"statusbar"`. The host decides where (and whether) to
/// mount it — bottom footer today, top bar tomorrow.
///
/// Facts enter two ways: host-pushed setters (`set_model`, `set_custom`,
/// ...) and the shared `@devkit.EventBus` (topic `"status"`, see
/// `bus_view.mbt`) — the cross-extension channel. Peers publish segment
/// facts unconditionally; without a status bar subscribed, a publish is a
/// silent no-op.

///|
/// Segment ids the bar knows how to render, in default order.
pub fn available_segments() -> Array[String] {
  [
    "model", "effort", "turn", "tools", "tok", "cache", "ttft", "tps", "avg", "session",
    "lat",
  ]
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
  /// Session-cumulative tool-call count: never reset by a new turn, so the
  /// bar keeps showing what the session did (a per-turn counter would flash
  /// back to 0 the moment turn 2 starts without a tool call).
  mut tool_calls : Int
  mut tokens_in : Int
  mut tokens_out : Int
  /// Latest model round's input size and cached portion — the cache hit
  /// rate is cached/input of that round ("each round summarized").
  mut round_cached : Int?
  mut round_input : Int?
  /// Per-round token-efficiency timings (all None until a clock is
  /// injected and the first streamed round completes):
  /// `round_started_ms`/`first_token_ms` anchor the CURRENT round; the
  /// rest summarize the LAST completed round.
  mut round_started_ms : Int64?
  mut first_token_ms : Int64?
  mut ttft_ms : Int?
  mut round_gen_ms : Int?
  mut round_tps : Double?
  mut sum_tps : Double
  mut tps_rounds : Int
  mut turn_started_ms : Int64?
  mut session_id : String?
  mut latency_ms : Int?
  /// Peer-published segments (id → display text). Insertion-ordered.
  custom : Map[String, String]
}

///|
fn StatusBarState::StatusBarState() -> StatusBarState {
  {
    model: None,
    effort: None,
    turn_count: 0,
    tool_calls: 0,
    tokens_in: 0,
    tokens_out: 0,
    round_cached: None,
    round_input: None,
    round_started_ms: None,
    first_token_ms: None,
    ttft_ms: None,
    round_gen_ms: None,
    round_tps: None,
    sum_tps: 0.0,
    tps_rounds: 0,
    turn_started_ms: None,
    session_id: None,
    latency_ms: None,
    custom: Map([]),
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
    "tools" => Some(state.tool_calls.to_string())
    "tok" =>
      Some(
        state.tokens_in.to_string() +
        "↑ " +
        state.tokens_out.to_string() +
        "↓",
      )
    "cache" =>
      // Latest round's hit rate; hidden until a provider reports both the
      // cached portion and the prompt total for some round.
      match (state.round_cached, state.round_input) {
        (Some(cached), Some(input)) =>
          if input > 0 {
            Some((cached * 100 / input).to_string() + "%")
          } else {
            None
          }
        _ => None
      }
    "ttft" =>
      // Time to first streamed token of the last completed round.
      match state.ttft_ms {
        Some(ms) => Some(ms.to_string() + "ms")
        None => None
      }
    "tps" =>
      // Last round's output tokens per second over the whole round span
      // (request start → response committed).
      match state.round_tps {
        Some(tps) => Some(fmt_one_decimal(tps) + "/s")
        None => None
      }
    "avg" => {
      // Session average of per-round tps over rounds that reported usage.
      let rounds = state.tps_rounds
      if rounds > 0 {
        Some(fmt_one_decimal(state.sum_tps / rounds.to_double()) + "/s")
      } else {
        None
      }
    }
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
    // Peer-published segment: renders when a fact exists, silently skipped
    // otherwise (the same rule every built-in follows).
    other => state.custom.get(other)
  }
}

///|
/// One decimal place, integer math: deterministic across float formatting.
fn fmt_one_decimal(value : Double) -> String {
  let tenths = (value * 10.0 + 0.5).to_int()
  "\{tenths / 10}.\{tenths % 10}"
}

///|
/// The status bar extension. One struct, three port views: `Observer`
/// (self-collects turn/token telemetry), `CommandPort` (`/statusbar`
/// customization), and `Extension` (self-reporting manifest).
pub struct StatusBar {
  ui : &@posoco.UiPort
  state : StatusBarState
  /// Monotonic-enough millisecond source for the efficiency segments.
  /// Injected so tests drive time deterministically; defaults to
  /// `@async.now()`. Timing segments stay hidden for hosts that pass a
  /// constant clock only in tests — no clock, no numbers.
  clock : () -> Int64
  mut items : Array[String]
}

///|
/// Compose a status bar over the host's `UiPort`. `items` selects and orders
/// segments; unknown ids are ignored at render time (the `/statusbar`
/// command validates strictly instead).
pub fn StatusBar::StatusBar(
  ui : &@posoco.UiPort,
  items? : Array[String] = default_items(),
  bus? : @devkit.EventBus? = None,
  clock? : () -> Int64 = fn() { @async.now() },
) -> StatusBar {
  let bar : StatusBar = { ui, state: StatusBarState(), items, clock }
  match bus {
    Some(bus) => bus.subscribe(bar as &@devkit.BusSubscriber)
    None => ()
  }
  bar
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
  // Custom facts the layout does not already place render after it, in
  // first-arrival order — peers that publish always show up without the
  // user re-running /statusbar.
  for id, value in self.state.custom {
    if !self.items.contains(id) {
      pairs.push((id, value))
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
/// Host-pushed custom segment fact: `id` names the segment (rendered as-is,
/// e.g. `"cache"`), `value` its display text. Same channel as bus-published
/// facts — a bus publish of `{"cache": "62%"}` on topic `"status"` is
/// equivalent to `set_custom("cache", "62%")`.
pub fn StatusBar::set_custom(
  self : StatusBar,
  id : String,
  value : String,
) -> Unit {
  self.state.custom[id] = value
  self.render()
}

///|
/// Drop one custom segment fact. The segment stops rendering until a new
/// fact arrives.
pub fn StatusBar::clear_custom(self : StatusBar, id : String) -> Unit {
  ignore(self.state.custom.remove(id))
  self.render()
}

///|
/// Live custom segment ids in first-arrival order.
pub fn StatusBar::custom_segments(self : StatusBar) -> Array[String] {
  let ids : Array[String] = []
  for id, _value in self.state.custom {
    ids.push(id)
  }
  ids
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
