///|
/// Status-bar publication of Codex quota windows.
///
/// Codex is push-shaped: the authoritative 5-hour and weekly percentages
/// ride on chat responses (header capture) or the usage endpoint, both of
/// which land in a `CodexQuotaTracker`. This extension is the consumer end
/// of that pipeline: it observes `ModelResponseReceived` and tracker
/// captures, replays the tracker snapshot as `5h` / `weekly` status segments
/// as `@kit_events.StatusChanged` ops, and unregisters windows whose reading
/// disappeared. The router's `@kit_events.ProviderStatus` announcements scope
/// that visibility to the codex provider; with no event capability every
/// publication is a silent no-op.

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
  /// Owner-bound posoco event capability (`Extension("posoco_ext_openai")`):
  /// the publisher announces its windows as `StatusChanged` ops through it and
  /// listens on it for the router's `ProviderStatus`. `None` disables
  /// publication and the provider listener.
  events : @posoco.Events?
  /// Whether the provider listener was already registered on the channel, so a
  /// repeated `on_compose` never double-subscribes.
  mut attached : Bool
  mut last : Array[@devkit.QuotaReading]
  /// Active provider last announced by a `ProviderStatus` event. `None`
  /// until one arrives — no announcements keep the windows visible.
  priv mut active_provider : String?
  /// This registration's tracker subscription token — the only handle that
  /// unsubscribes it, so shutdown never detaches a coexisting publisher.
  priv mut token : Int32?
}

///|
/// Compose a quota publisher. Defaults to the process-shared tracker so the
/// ports built by the provider factory and this publisher observe the same
/// snapshot without host plumbing; hosts that want isolation pass their own.
/// When a capability is given, the publisher subscribes to it immediately so
/// the router's `ProviderStatus` announcements can drive window visibility —
/// construction happens before composition, so the initial announcement the
/// router makes while composing is not missed.
pub fn CodexQuotaStatus::CodexQuotaStatus(
  events~ : @posoco.Events? = None,
  tracker~ : CodexQuotaTracker? = None,
) -> CodexQuotaStatus {
  let status : CodexQuotaStatus = {
    tracker: match tracker {
      Some(value) => value
      None => codex_shared_quota_tracker()
    },
    events,
    attached: false,
    last: [],
    active_provider: None,
    token: None,
  }
  status.attach_events()
  // Tracker changes reach the bar even when they land outside this
  // publisher's own triggers: the startup usage probe fills the shared
  // tracker after compose and before any chat response exists. The token
  // stays publisher-owned, so coexisting lifetimes never detach each other.
  status.token = Some(
    status.tracker.subscribe(notify=fn() { status.publish_if_changed() }),
  )
  status
}

///|
/// The capability this publisher announces and listens on: the host-injected
/// one. `None` means there is no channel at all and every publication is a
/// silent no-op.
fn CodexQuotaStatus::channel(self : CodexQuotaStatus) -> @posoco.Events? {
  self.events
}

///|
/// Register the provider listener once. With an injected capability this
/// happens at construction — before composition, so the router's compose-time
/// `ProviderStatus` is not missed.
fn CodexQuotaStatus::attach_events(self : CodexQuotaStatus) -> Unit {
  if self.attached {
    return
  }
  match self.channel() {
    Some(events) =>
      match
        events.subscribe(fn(envelope) { self.on_provider_event(envelope) }) {
        Ok(_) => self.attached = true
        Err(_) => ()
      }
    None => ()
  }
}

///|
/// Publish one status op on behalf of this extension. A closed channel is
/// dropped silently: status publication is a rendering path, never an error
/// path.
fn CodexQuotaStatus::publish_status(
  self : CodexQuotaStatus,
  op : @kit_events.StatusOp,
) -> Unit {
  match self.channel() {
    Some(events) => ignore(events.publish(@kit_events.StatusChanged(op)))
    None => ()
  }
}

///|
/// Republish when the snapshot changed; identical snapshots stay silent so
/// unrelated providers' turns never spam the channel. Windows that were
/// published before but vanished from the snapshot are unregistered, so a
/// stale percentage never lingers on the bar. While another provider is
/// active (a `ProviderStatus` announced it) every trigger is gated off:
/// `on_provider_event` already unregistered the windows and nothing re-claims
/// them until codex re-activates. A stopped publisher (shutdown detached its
/// tracker token) never publishes: the event registration survives shutdown,
/// so every path through here is gated on the live subscription.
fn CodexQuotaStatus::publish_if_changed(self : CodexQuotaStatus) -> Unit {
  if self.token is None {
    return
  }
  if self.channel() is None {
    return
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
          self.publish_status(
            @kit_events.Register(
              segment=reading.window,
              label=None,
              priority=45,
              value=Some(format_quota_percent(left) + "% left"),
              color=quota_color_role(left),
            ),
          )
        }
        None => ()
      }
    }
  }
  for window in previous {
    if !published.contains(window) {
      self.publish_status(@kit_events.Unregister(segment=window))
    }
  }
}

///|
pub impl @posoco.Observer for CodexQuotaStatus with fn on_event(
  self : CodexQuotaStatus,
  _scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    ModelResponseReceived(..) => self.publish_if_changed()
    _ => ()
  }
}

///|
pub extend CodexQuotaStatus with @posoco.Observer::{on_event}

///|
/// Provider visibility over the event channel: the router announces the
/// active provider with `@kit_events.ProviderStatus` at compose and on every
/// switch, idempotently. Codex windows belong on the bar only while codex is
/// that provider — another id unregisters every published window (`last` is
/// cleared, so the next codex publication sees a change) and gates further
/// publications; "openai" republishes immediately. Every other event (the
/// status and selection traffic sharing the channel) is ignored, and the
/// typed payload cannot be malformed. Delivery is not filtered by publisher:
/// `ProviderStatus` stays a single-producer protocol fact (`publisher_id` is
/// available should a peer need to narrow it). Without a capability there is no
/// subscription, so visibility never flips and hosts without a router keep the
/// old always-visible behavior. A stopped publisher ignores every event: the
/// registration outlives shutdown, and acting on late provider announcements
/// would strip a successor's windows or republish behind its back.
fn CodexQuotaStatus::on_provider_event(
  self : CodexQuotaStatus,
  envelope : @posoco.EventEnvelope,
) -> Unit {
  if self.token is None {
    return
  }
  let provider_id = match @kit_events.provider_status_of(envelope) {
    Some(payload) => payload.provider_id
    None => return
  }
  if provider_id == "openai" {
    self.active_provider = Some("openai")
    self.publish_if_changed()
    return
  }
  self.active_provider = Some(provider_id)
  if self.channel() is None {
    // No channel means no subscription, so this arm is unreachable; staying
    // silent keeps the listener non-raising either way.
    return
  }
  for reading in self.last {
    if is_quota_segment(reading) {
      self.publish_status(@kit_events.Unregister(segment=reading.window))
    }
  }
  self.last = []
}

///|
/// Refresh probes or history replay may already have filled the tracker
/// when the agent composes, so compose publishes immediately instead of
/// waiting for the first model response. The composed view is unused:
/// publication rides the injected capability alone.
pub impl @posoco.Lifecycle for CodexQuotaStatus with fn on_compose(
  self : CodexQuotaStatus,
  _ctx : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  self.attach_events()
  self.publish_if_changed()
}

///|
pub extend CodexQuotaStatus with @posoco.Lifecycle::{
  on_compose,
  on_shutdown,
  on_start,
}

///|
/// Release this publisher's tracker registration: the tracker is
/// process-shared and outlives any single publisher, so shutdown detaches
/// exactly its own token and leaves coexisting publishers subscribed.
pub impl @posoco.Lifecycle for CodexQuotaStatus with fn on_shutdown(
  self : CodexQuotaStatus,
) -> Unit {
  match self.token {
    Some(token) => {
      self.tracker.unsubscribe(token)
      self.token = None
    }
    None => ()
  }
}

///|
pub impl @posoco.Extension for CodexQuotaStatus with fn extension_id(
  _self : CodexQuotaStatus,
) -> String {
  "posoco_ext_openai_quota"
}

///|
pub extend CodexQuotaStatus with @posoco.Extension::{manifest, extension_id}

///|
pub impl @posoco.Extension for CodexQuotaStatus with fn manifest(
  self : CodexQuotaStatus,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_openai_quota", observers=[self], lifecycle=[
    self,
  ])
}
