///|
/// Session usage attribution for `/profile save`: an Observer that counts
/// successful tool executions per session. A deferred tool executes as its own
/// child call, so `ToolCallSucceeded` already names the real tool — the gateway
/// envelope (`tool_execute`) is never an attributable name and cannot
/// double-count.

///|
/// Watch committed tool results. Only successful executions count (failed,
/// rejected, and abandoned calls never attribute usage), only tools present
/// in the static attribution table count, and everything is keyed by
/// session: a long-lived Agent serves many sessions, and an unscoped bucket
/// would corrupt every save — out-of-run diagnostics carrying no scope are
/// skipped.
pub impl @posoco.Observer for Profiles with fn on_event(
  self : Profiles,
  scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::ToolCallSucceeded(call~, ..) => {
      let session_id = match scope {
        Some(s) => s.session_id.to_string()
        None => return
      }
      let name = call.name.to_string()
      if self.attribution.contains(name) {
        let per_session = match self.usage.get(session_id) {
          Some(map) => map
          None => {
            let map : Map[String, Int32] = Map::from_array([])
            self.usage[session_id] = map
            map
          }
        }
        per_session[name] = match per_session.get(name) {
          Some(n) => n + 1
          None => 1
        }
      }
    }
    _ => ()
  }
}

///|
/// Aggregated ext usage for one session — the summarizer input for
/// `/profile save`. Counts are folded from tool names to ext ids through
/// the attribution table (tools with no owner are dropped), sorted by
/// count descending with ext id as the deterministic tie-break.
pub fn Profiles::session_usage(
  self : Profiles,
  session_id : String,
) -> Array[(String, Int32)] {
  let per_ext : Map[String, Int32] = Map::from_array([])
  match self.usage.get(session_id) {
    Some(tools) =>
      for name, count in tools {
        match self.attribution.get(name) {
          Some(ext_id) =>
            per_ext[ext_id] = match per_ext.get(ext_id) {
              Some(n) => n + count
              None => count
            }
          None => ()
        }
      }
    None => ()
  }
  let pairs : Array[(String, Int32)] = []
  for ext_id, count in per_ext {
    pairs.push((ext_id, count))
  }
  pairs.sort_by(fn(a, b) {
    if a.1 != b.1 {
      b.1 - a.1
    } else if a.0 < b.0 {
      -1
    } else if a.0 > b.0 {
      1
    } else {
      0
    }
  })
  pairs
}
