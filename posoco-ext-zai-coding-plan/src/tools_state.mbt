///|
/// Lifecycle of the provider-owned tool plane, as the status bar reports it.
///
/// The segment states are deliberately more than "on/off": a switch can be
/// *declared but still connecting*, and a partial connect must not read as
/// success. Publication happens at operation boundaries (Posoco captures the
/// tool face per operation), so the bar is allowed to show `2/3` for a moment —
/// that is information, not an error.
///
/// Rendering is pure: callers publish a value and a colour role, never a
/// sentence, so the UI decides placement and wording.

///|
#derive(Eq, Debug)
pub(all) enum ZaiToolsState {
  /// No provider tool group is announced (another model is active, or the
  /// plane was never started). The segment is hidden.
  Inactive
  /// A connect attempt is in flight; `connected` of `total` servers answered.
  Connecting(connected~ : Int32, total~ : Int32)
  /// Every declared server connected; the group is announced.
  Ready(total~ : Int32)
  /// Some servers failed; the rest are announced and the failure stays
  /// visible instead of collapsing into success.
  Degraded(connected~ : Int32, total~ : Int32)
  /// The group was withdrawn (soft) and the connections are waiting for the
  /// last operation reference to be released; the segment is hidden.
  Withdrawing(total~ : Int32)
}

///|
pub extend ZaiToolsState with Eq::{not_equal, equal}

///|
pub extend ZaiToolsState with Debug::{to_repr}

///|
/// Keep a count inside `0..=total` so a buggy plane cannot render `4/3`.
fn zai_tools_clamp_count(count : Int32, total : Int32) -> Int32 {
  if total <= 0 {
    0
  } else if count < 0 {
    0
  } else if count > total {
    total
  } else {
    count
  }
}

///|
/// Total declared servers for a state, or 0 for `Inactive`.
pub fn ZaiToolsState::total(self : ZaiToolsState) -> Int32 {
  match self {
    Inactive => 0
    Connecting(total~, ..)
    | Ready(total~)
    | Degraded(total~, ..)
    | Withdrawing(total~) => total
  }
}

///|
/// Connected server count for a state, or 0 for the terminal-free states.
pub fn ZaiToolsState::connected(self : ZaiToolsState) -> Int32 {
  match self {
    Inactive | Withdrawing(..) => 0
    Connecting(connected~, total~) => zai_tools_clamp_count(connected, total)
    Ready(total~) => if total < 0 { 0 } else { total }
    Degraded(connected~, total~) => zai_tools_clamp_count(connected, total)
  }
}

///|
/// Status-bar value (`n/m`), or `None` when the segment must disappear.
pub fn ZaiToolsState::segment_value(self : ZaiToolsState) -> String? {
  match self {
    Inactive | Withdrawing(..) => None
    _ => Some(self.connected().to_string() + "/" + self.total().to_string())
  }
}

///|
/// Status-bar colour role (`posoco/devkit` vocabulary), or `None` to inherit
/// the bar's default styling.
pub fn ZaiToolsState::segment_color(self : ZaiToolsState) -> String? {
  match self {
    Inactive | Withdrawing(..) => None
    Connecting(..) => Some("info")
    Ready(..) => Some("success")
    Degraded(..) => Some("warning")
  }
}

///|
/// Transition after one connect attempt settled: every declared server
/// connected becomes `Ready`, a partial result stays `Degraded`.
pub fn ZaiToolsState::settled(
  connected~ : Int32,
  total~ : Int32,
) -> ZaiToolsState {
  let clamped = zai_tools_clamp_count(connected, total)
  if total > 0 && clamped == total {
    ZaiToolsState::Ready(total~)
  } else {
    ZaiToolsState::Degraded(connected=clamped, total~)
  }
}

///|
/// Bar text: the count plus the provider's own name for the plane, so the
/// segment reads on its own (`3/3 Official MCP`) without a legend.
pub fn zai_mcp_segment_text(value : String) -> String {
  value + " Official MCP"
}
