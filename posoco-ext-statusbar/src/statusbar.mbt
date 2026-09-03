///|
/// posoco_ext_statusbar — a pure status-bar bridge.
///
/// The bar knows nothing about agents, turns, or tokens. Peer extensions
/// own every segment: they publish `register` / `update` / `unregister`
/// ops on the shared `@devkit.EventBus` (topic `"status"`, wire protocol
/// in `@devkit.status_op`), and the bar keeps one registry entry per
/// segment and projects the whole registry into a single
/// `UiSlot::Status` render intent (key `"statusbar"`) through the
/// composed UI. The host decides where (and whether) to mount it.
///
/// Ownership: the first source to register-or-update a segment owns it;
/// operations from any other source are ignored (no state change, no
/// render). Hosts and tests that bypass the bus can drive the same
/// semantics through `set_segment` / `clear_segment`.

///|
/// Public snapshot of one registry entry. `color` is a semantic role from
/// the devkit vocabulary (`status_color_roles()`), never a raw color value.
pub(all) struct SegmentInfo {
  segment : String
  owner : String
  label : String?
  priority : Int
  value : String?
  color : String?
} derive(Debug, Eq)

///|
/// Internal registry entry. `first_seen` (from a monotonic counter) breaks
/// priority ties so equal-priority segments keep registration order.
priv struct SegmentEntry {
  owner : String
  label : String?
  priority : Int
  mut value : String?
  color : String?
  first_seen : Int
}

///|
/// Keep only vocabulary roles: a known `status_color_roles()` name passes
/// through; unknown or absent colors become `None`, so hosts never see a
/// non-vocabulary string.
fn vocabulary_color(color : String?) -> String? {
  match color {
    Some(role) =>
      if @devkit.is_status_color_role(role) {
        Some(role)
      } else {
        None
      }
    None => None
  }
}

///|
/// The status bar bridge: one struct, four port views — `BusSubscriber`
/// (consumes status ops from the shared event bus), `CommandPort`
/// (`/statusbar` provider listing), `Lifecycle` (receives the composed
/// UI), and `Extension` (self-reporting manifest).
pub struct StatusBar {
  /// The composed UI, delivered at `Lifecycle::on_compose`. `None` until
  /// then — applied changes stay silent instead of rendering nowhere.
  priv mut ui : &@posoco.UiPort?
  priv registry : Map[String, SegmentEntry]
  priv mut counter : Int
}

///|
/// Compose a status bar bridge. When a bus is given, the bar subscribes to
/// it immediately; render intents start flowing only after the composed UI
/// arrives at `on_compose`.
pub fn StatusBar::StatusBar(bus? : @devkit.EventBus? = None) -> StatusBar {
  let bar : StatusBar = { ui: None, registry: Map::from_array([]), counter: 0, }
  match bus {
    Some(bus) => bus.subscribe(bar as &@devkit.BusSubscriber)
    None => ()
  }
  bar
}

///|
fn StatusBar::next_seen(self : StatusBar) -> Int {
  self.counter += 1
  self.counter
}

///|
/// Apply a register op. The first source to claim a segment owns it; the
/// owner may overwrite metadata including `color` (keeping the original
/// `first_seen`); foreign sources are ignored. The incoming color is
/// filtered through `vocabulary_color`: unknown roles are silently
/// de-colored, so hosts never see a non-vocabulary string.
fn StatusBar::apply_register(
  self : StatusBar,
  source : String,
  segment : String,
  label : String?,
  priority : Int,
  value : String?,
  color : String?,
) -> Bool {
  let color = vocabulary_color(color)
  match self.registry.get(segment) {
    Some(existing) =>
      if existing.owner != source {
        false
      } else {
        self.registry[segment] = {
          owner: source,
          label,
          priority,
          value,
          color,
          first_seen: existing.first_seen,
        }
        true
      }
    None => {
      self.registry[segment] = {
        owner: source,
        label,
        priority,
        value,
        color,
        first_seen: self.next_seen(),
      }
      true
    }
  }
}

///|
/// Apply an update op: set the segment's value. An unknown segment
/// auto-registers (owner = source, priority 0, no label); foreign sources
/// are ignored.
fn StatusBar::apply_update(
  self : StatusBar,
  source : String,
  segment : String,
  value : String,
) -> Bool {
  match self.registry.get(segment) {
    Some(existing) =>
      if existing.owner != source {
        false
      } else {
        existing.value = Some(value)
        true
      }
    None => {
      self.registry[segment] = {
        owner: source,
        label: None,
        priority: 0,
        value: Some(value),
        color: None,
        first_seen: self.next_seen(),
      }
      true
    }
  }
}

///|
/// Apply an unregister op: remove the segment. Only the owner may release
/// it; foreign or unknown segments are ignored.
fn StatusBar::apply_unregister(
  self : StatusBar,
  source : String,
  segment : String,
) -> Bool {
  match self.registry.get(segment) {
    Some(existing) =>
      if existing.owner == source {
        ignore(self.registry.remove(segment))
        true
      } else {
        false
      }
    None => false
  }
}

///|
/// Consume one bus event: decode the status-op wire protocol and apply it.
/// Malformed events (wrong topic, bad payload) decode to `None` and are
/// dropped without a render; ownership-rejected ops are dropped the same
/// way. Every APPLIED change renders exactly once — even one that empties
/// the bar (an empty Entries body clears the host line).
pub impl @devkit.BusSubscriber for StatusBar with fn on_bus_event(
  self : StatusBar,
  event : @devkit.BusEvent,
) -> Unit {
  match @devkit.decode_status_op(event) {
    Some(Register(segment~, label~, priority~, value~, color~)) =>
      if self.apply_register(
          event.source,
          segment,
          label,
          priority,
          value,
          color,
        ) {
        self.render()
      }
    Some(Update(segment~, value~)) =>
      if self.apply_update(event.source, segment, value) {
        self.render()
      }
    Some(Unregister(segment~)) =>
      if self.apply_unregister(event.source, segment) {
        self.render()
      }
    None => ()
  }
}

///|
/// Direct path, same semantics as a bus `update` op: set `segment` on
/// behalf of `source` (auto-registering unknown segments, rejecting
/// foreign owners). Not a bus publish — hosts and tests drive the bar
/// without a round trip.
pub fn StatusBar::set_segment(
  self : StatusBar,
  source~ : String,
  segment~ : String,
  value~ : String,
) -> Unit {
  if self.apply_update(source, segment, value) {
    self.render()
  }
}

///|
/// Direct path, same semantics as a bus `unregister` op.
pub fn StatusBar::clear_segment(
  self : StatusBar,
  source~ : String,
  segment~ : String,
) -> Unit {
  if self.apply_unregister(source, segment) {
    self.render()
  }
}

///|
/// Registry entries in display order: priority ascending, then
/// first-seen ascending (equal priorities keep registration order).
fn StatusBar::ordered(self : StatusBar) -> Array[(String, SegmentEntry)] {
  let entries : Array[(String, SegmentEntry)] = []
  for segment, entry in self.registry {
    entries.push((segment, entry))
  }
  entries.sort_by(fn(a, b) {
    if a.1.priority != b.1.priority {
      a.1.priority - b.1.priority
    } else {
      a.1.first_seen - b.1.first_seen
    }
  })
  entries
}

///|
/// Public snapshot of the registry, in display order — visible and
/// valueless segments alike.
pub fn StatusBar::segments(self : StatusBar) -> Array[SegmentInfo] {
  self
  .ordered()
  .map(fn(pair) {
    let (segment, entry) = pair
    {
      segment,
      owner: entry.owner,
      label: entry.label,
      priority: entry.priority,
      value: entry.value,
      color: entry.color,
    }
  })
}

///|
/// Project the whole registry into one render intent. Only segments with
/// a value are visible; an empty bar renders an empty Entries body, which
/// the host treats as "clear the line". The body is always `Entries` —
/// `KeyValue` remains in core for other producers. No composed UI yet:
/// stay silent.
fn StatusBar::render(self : StatusBar) -> Unit {
  let ui = match self.ui {
    Some(ui) => ui
    None => return
  }
  let entries : Array[@posoco.UiEntry] = []
  for pair in self.ordered() {
    let (segment, entry) = pair
    match entry.value {
      Some(value) => entries.push({ key: segment, value, color: entry.color, })
      None => ()
    }
  }
  ui.render(@posoco.UiRender::{
    slot: @posoco.UiSlot::Status,
    key: "statusbar",
    title: None,
    body: @posoco.UiBody::Entries(entries),
    ttl_ms: None,
  })
}
