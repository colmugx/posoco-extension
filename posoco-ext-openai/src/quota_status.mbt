///|
/// Status-bar publication of Codex quota windows.
///
/// Codex is push-shaped: the authoritative 5-hour and weekly percentages
/// ride on chat responses (header capture) or the usage endpoint, both of
/// which land in a `CodexQuotaTracker`. This extension is the consumer end
/// of that pipeline: it observes `ModelResponseReceived`, replays the
/// tracker snapshot as `5h` / `weekly` status segments through the devkit
/// status protocol, and unregisters windows whose reading disappeared.
/// Router provider events scope that visibility to the codex provider;
/// with `bus = None` every publication is a silent no-op.

///|
/// Windows worth a segment: the two rate-limit windows with a stated
/// percentage. The balance reading stays out of the bar (it is a funds
/// fact, not turn-budget pressure) but remains available through
/// `CodexQuotaTracker::snapshots`.
fn is_quota_segment(reading : @devkit.QuotaReading) -> Bool {
  (reading.window == "5h" || reading.window == "weekly") &&
  reading.used_percent is Some(_)
}

///|
/// Provider-stated percentages render without trailing `.0` noise.
fn format_quota_percent(value : Double) -> String {
  if value >= 0.0 && value == value.floor() && value < 1000000000.0 {
    value.to_int().to_string()
  } else {
    value.to_string()
  }
}

///|
/// Local coloring heuristic over provider-stated numbers (color is a UI
/// decision, never a data estimate), on the remaining axis: exhausted
/// windows read as errors, windows within 20% of exhaustion as warnings.
fn quota_color_role(left_percent : Double) -> String? {
  if left_percent <= 0.0 {
    Some("error")
  } else if left_percent <= 20.0 {
    Some("warning")
  } else {
    None
  }
}

///|
/// Publishes the latest Codex quota snapshot as status segments. One struct,
/// two port views: `Observer` (re-publication trigger) and `Extension`
/// (self-reporting manifest).
pub struct CodexQuotaStatus {
  tracker : CodexQuotaTracker
  bus : @devkit.EventBus?
  mut last : Array[@devkit.QuotaReading]
  /// Active provider last announced on the bus "provider" topic. `None`
  /// until one arrives — no router events keeps the windows visible.
  priv mut active_provider : String?
}

///|
/// Compose a quota publisher. Defaults to the process-shared tracker so the
/// ports built by the provider factory and this publisher observe the same
/// snapshot without host plumbing; hosts that want isolation pass their own.
/// When a bus is given, the publisher subscribes to it immediately so the
/// router's provider events can drive window visibility.
pub fn CodexQuotaStatus::CodexQuotaStatus(
  bus? : @devkit.EventBus? = None,
  tracker? : CodexQuotaTracker? = None,
) -> CodexQuotaStatus {
  let status : CodexQuotaStatus = {
    tracker: match tracker {
      Some(value) => value
      None => codex_shared_quota_tracker()
    },
    bus,
    last: [],
    active_provider: None,
  }
  match bus {
    Some(bus) => bus.subscribe(status as &@devkit.BusSubscriber)
    None => ()
  }
  status
}

///|
/// Republish when the snapshot changed; identical snapshots stay silent so
/// unrelated providers' turns never spam the bus. Windows that were
/// published before but vanished from the snapshot are unregistered, so a
/// stale percentage never lingers on the bar. While another provider is
/// active (a provider event announced it) every trigger is gated off:
/// `on_bus_event` already unregistered the windows and nothing re-claims
/// them until codex re-activates.
fn CodexQuotaStatus::publish_if_changed(self : CodexQuotaStatus) -> Unit {
  let bus = match self.bus {
    Some(bus) => bus
    None => return
  }
  match self.active_provider {
    Some(id) => if id != "openai" { return }
    None => ()
  }
  let current = self.tracker.snapshots()
  if current == self.last {
    return
  }
  let previous : Array[String] = []
  for reading in self.last {
    if is_quota_segment(reading) {
      previous.push(reading.window)
    }
  }
  self.last = current
  let published : Array[String] = []
  for reading in current {
    if is_quota_segment(reading) {
      published.push(reading.window)
      match reading.used_percent {
        Some(percent) => {
          // codex CLI speaks in remaining quota: used 45% renders "55% left".
          let left = 100.0 - percent
          match quota_color_role(left) {
            Some(role) =>
              @devkit.publish_status_register(
                bus,
                source="posoco_ext_openai",
                segment=reading.window,
                priority=45,
                value=format_quota_percent(left) + "% left",
                color=role,
              )
            None =>
              @devkit.publish_status_register(
                bus,
                source="posoco_ext_openai",
                segment=reading.window,
                priority=45,
                value=format_quota_percent(left) + "% left",
              )
          }
        }
        None => ()
      }
    }
  }
  for window in previous {
    if !published.contains(window) {
      @devkit.publish_status_unregister(
        bus,
        source="posoco_ext_openai",
        segment=window,
      )
    }
  }
}

///|
pub impl @posoco.Observer for CodexQuotaStatus with fn on_event(
  self : CodexQuotaStatus,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    ModelResponseReceived(..) => self.publish_if_changed()
    _ => ()
  }
}

///|
/// Provider visibility over the bus: the router announces the active
/// provider on the "provider" topic (`data.provider_id`), at compose and on
/// every switch, idempotently. Codex windows belong on the bar only while
/// codex is that provider — another id unregisters every published window
/// (`last` is cleared, so the next codex publication sees a change) and
/// gates further publications; "openai" republishes immediately. Events on
/// other topics, or with a missing/mistyped `provider_id`, are ignored.
/// Without a bus there is no subscription, so visibility never flips and
/// hosts without a router keep the old always-visible behavior.
pub impl @devkit.BusSubscriber for CodexQuotaStatus with fn on_bus_event(
  self : CodexQuotaStatus,
  event : @devkit.BusEvent,
) -> Unit {
  if event.topic != "provider" {
    return
  }
  let provider_id = match event.data {
    Json::Object(fields) =>
      match fields.get("provider_id") {
        Some(Json::String(id)) => id
        _ => return
      }
    _ => return
  }
  if provider_id == "openai" {
    self.active_provider = Some("openai")
    self.publish_if_changed()
    return
  }
  self.active_provider = Some(provider_id)
  let bus = match self.bus {
    Some(bus) => bus
    // No subscription exists without a bus, so this arm is unreachable;
    // staying silent keeps the handler non-raising either way.
    None => return
  }
  for reading in self.last {
    if is_quota_segment(reading) {
      @devkit.publish_status_unregister(
        bus,
        source="posoco_ext_openai",
        segment=reading.window,
      )
    }
  }
  self.last = []
}

///|
/// Refresh probes or history replay may already have filled the tracker
/// when the agent composes, so compose publishes immediately instead of
/// waiting for the first model response. The composed view is unused:
/// publication rides the bus alone.
pub impl @posoco.Lifecycle for CodexQuotaStatus with fn on_compose(
  self : CodexQuotaStatus,
  _ctx : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  self.publish_if_changed()
}

///|
/// Nothing to release: the publisher holds no resources beyond the tracker.
pub impl @posoco.Lifecycle for CodexQuotaStatus with fn on_shutdown(
  self : CodexQuotaStatus,
) -> Unit {
  ignore(self)
}

///|
pub impl @posoco.Extension for CodexQuotaStatus with fn extension_id(
  _self : CodexQuotaStatus,
) -> String {
  "posoco_ext_openai_quota"
}

///|
pub impl @posoco.Extension for CodexQuotaStatus with fn manifest(
  self : CodexQuotaStatus,
) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_openai_quota",
    models: [],
    tools: [],
    sessions: [],
    observers: [self],
    hooks: [],
    memory: [],
    lifecycle: [self],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}
