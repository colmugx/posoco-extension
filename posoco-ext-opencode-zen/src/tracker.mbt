///|
/// Per-session spend accounting with a statusbar push.
///
/// The tracker is provider-owned: each provider extension instantiates its
/// own with its source id, records one estimated cost per settled model
/// call, and publishes the calling session's cumulative total as a statusbar
/// segment through the process default bus (same channel as the `cache`
/// segment). With no bus registered the accounting still happens and the
/// publish is a silent skip — a rendering gap, never an error.
pub(all) struct ZenSpendTracker {
  /// The status source this tracker publishes under
  /// (e.g. "posoco_ext_opencode_zen").
  source : String
  /// Cumulative USD per session id.
  buckets : Map[String, Double]
} derive(Eq, Debug)

///|
pub extend ZenSpendTracker with Eq::{not_equal, equal}

///|
pub extend ZenSpendTracker with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn ZenSpendTracker::ZenSpendTracker(
  source~ : String = "posoco_ext_opencode_zen",
) -> ZenSpendTracker {
  { source, buckets: Map::from_array([]), }
}

///|
/// Record one settled step's cost and return the session's new total.
fn ZenSpendTracker::record(
  self : ZenSpendTracker,
  session_id : String,
  cost : Double,
) -> Double {
  let previous = match self.buckets.get(session_id) {
    Some(total) => total
    None => 0.0
  }
  let total = previous + cost
  self.buckets[session_id] = total
  total
}

///|
/// The session's cumulative spend, `None` before the first recorded step.
pub fn ZenSpendTracker::session_spend(
  self : ZenSpendTracker,
  session_id : String,
) -> Double? {
  self.buckets.get(session_id)
}

///|
/// Record a settled step and publish the session total to the default bus.
/// No-op when no bus is registered.
pub fn ZenSpendTracker::record_and_publish(
  self : ZenSpendTracker,
  session_id : String,
  cost : Double,
) -> Unit {
  let total = self.record(session_id, cost)
  match @devkit.status_bus_default() {
    Some(bus) =>
      @devkit.publish_status_register(
        bus,
        source=self.source,
        segment="spent",
        label="$",
        priority=85,
        value=zen_format_usd(total),
      )
    None => ()
  }
}

///|
/// Process-singleton trackers keyed by status source. The port holds no
/// state of its own (slots rebuild freely), so the buckets live at process
/// scope — the same lifetime the statusbar segment reports. Each product
/// (zen, go, ...) owns its source id and therefore its own buckets.
let zen_spend_cells : Ref[Map[String, ZenSpendTracker]] = Ref::{
  val: Map::from_array([]),
}

///|
pub fn zen_spend_tracker_for(source : String) -> ZenSpendTracker {
  match zen_spend_cells.val.get(source) {
    Some(tracker) => tracker
    None => {
      let tracker = ZenSpendTracker::ZenSpendTracker(source~)
      zen_spend_cells.val[source] = tracker
      tracker
    }
  }
}

///|
/// The zen product's tracker (the historical default source).
pub fn zen_spend_tracker() -> ZenSpendTracker {
  zen_spend_tracker_for("posoco_ext_opencode_zen")
}
