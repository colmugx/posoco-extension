///|
/// Session usage attribution for `/profile save` (Q15): an Observer that
/// counts successful tool executions per session, unwrapping lazytools
/// gateway calls to their inner tool name first.

///|
/// Inner tool identity of an executed call. Gateway calls travel as
/// `tool_execute` with the real name in the `tool` argument — the same
/// field convention as lazytools' `unwrap_call` (own copy; no private
/// imports). Non-gateway calls and malformed gateway envelopes keep their
/// outer name.
fn inner_tool_name(name : String, arguments : Json) -> String {
  if name != "tool_execute" {
    return name
  }
  match arguments {
    Json::Object(fields) =>
      match fields.get("tool") {
        Some(Json::String(inner)) if inner != "" => inner
        _ => name
      }
    _ => name
  }
}

///|
/// Watch committed tool results. Only successful executions count
/// (`is_error` is derived from the outcome variant), only tools present in
/// the static attribution table count, and everything is keyed by session:
/// a long-lived Agent serves many sessions, and an unscoped bucket would
/// corrupt every save — out-of-run diagnostics carrying no scope are
/// skipped.
pub impl @posoco.Observer for Profiles with fn on_event_at(
  self : Profiles,
  scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::ToolCallResult(call~, is_error~, ..) => {
      if is_error {
        return
      }
      let session_id = match scope {
        Some(s) => s.session_id.to_string()
        None => return
      }
      let name = inner_tool_name(call.name.to_string(), call.arguments)
      if self.attribution.contains(name) {
        let per_session = match self.usage.get(session_id) {
          Some(map) => map
          None => {
            let map : Map[String, Int] = Map::from_array([])
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
pub extend Profiles with @posoco.Observer::{on_event}

///|
/// Aggregated ext usage for one session — the summarizer input for
/// `/profile save`. Counts are folded from tool names to ext ids through
/// the attribution table (tools with no owner are dropped), sorted by
/// count descending with ext id as the deterministic tie-break.
pub fn Profiles::session_usage(
  self : Profiles,
  session_id : String,
) -> Array[(String, Int)] {
  let per_ext : Map[String, Int] = Map::from_array([])
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
  let pairs : Array[(String, Int)] = []
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
