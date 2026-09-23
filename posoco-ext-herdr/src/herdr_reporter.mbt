///|
// Herdr presence: map Agent turn events onto herdr agent states and shell the
// `herdr` CLI so a cetas pane appears in the herdr agent rollup with live
// state. herdr injects HERDR_ENV / HERDR_PANE_ID into managed panes; without
// them the constructor returns None and nothing registers — zero cost when
// not under herdr.
//
// The state vocabulary is fixed by the installed herdr CLI
// (`idle|working|blocked|unknown`): there is NO `done` state, so both turn
// terminals report `idle` ("agent available again"). A rejected report is
// swallowed by design (presence must never fail a turn) — verify reports
// manually by running the CLI from README when debugging.
//
// While a `cetas` source holds the pane's lifecycle authority, herdr skips
// its own process probes, so the entry survives the process exiting. The
// Lifecycle impl releases that authority on Agent shutdown — the documented
// exit side of the custom-integration contract (`pane release-agent`).

///|
priv enum HerdrAgentState {
  Working
  Blocked
  Idle
}

///|
fn HerdrAgentState::cli_value(self : HerdrAgentState) -> String {
  match self {
    Working => "working"
    Blocked => "blocked"
    Idle => "idle"
  }
}

///|
priv struct HerdrConfig {
  pane : String
  bin : String
}

///|
pub struct HerdrReporter {
  pane : String
  bin : String
  spawn : (String, Array[String]) -> Unit
}

///|
fn HerdrReporter::from_config(cfg : HerdrConfig) -> HerdrReporter {
  { pane: cfg.pane, bin: cfg.bin, spawn: herdr_spawn_report, }
}

///|
/// Shared presence gate for the targets with environment access: HERDR_ENV
/// and HERDR_PANE_ID must be present and non-empty; HERDR_BIN_PATH defaults
/// to "herdr" when absent or blank. Pure, so native and js share one
/// detection decision.
#cfg(any(target="native", target="wasm", target="js"))
fn herdr_gate(marker : String?, pane : String?, bin : String?) -> HerdrConfig? {
  match (marker, pane) {
    (Some(marker), Some(pane)) if marker != "" && pane != "" => {
      let bin = match bin {
        Some(bin) if bin != "" => bin
        _ => "herdr"
      }
      Some({ pane, bin, })
    }
    _ => None
  }
}

///|
fn HerdrReporter::emit(self : HerdrReporter, state : HerdrAgentState) -> Unit {
  (self.spawn)(self.bin, [
    "pane",
    "report-agent",
    self.pane,
    "--source",
    "cetas",
    "--agent",
    "cetas",
    "--state",
    state.cli_value(),
  ])
}

///|
/// Bounded single-line report message: herdr renders it next to the agent
/// state in the rollup, so long multi-line prompts collapse to a hint.
fn report_message(text : String) -> String {
  let chars : Array[Char] = []
  let mut truncated = false
  for char in text {
    if chars.length() >= 120 {
      truncated = true
      break
    }
    match char {
      '\n' | '\r' => chars.push(' ')
      other => chars.push(other)
    }
  }
  let line = String::from_array(chars)
  if truncated {
    line + "…"
  } else {
    line
  }
}

///|
fn HerdrReporter::emit_message(
  self : HerdrReporter,
  state : HerdrAgentState,
  message : String,
) -> Unit {
  (self.spawn)(self.bin, [
    "pane",
    "report-agent",
    self.pane,
    "--source",
    "cetas",
    "--agent",
    "cetas",
    "--state",
    state.cli_value(),
    "--message",
    report_message(message),
  ])
}

///|
/// Drop this source's lifecycle authority for the pane. herdr keeps showing
/// the agent after the process exits while an authority is registered, so
/// every exit path that can reach Agent shutdown must fire this. Public for
/// host-side fatal-exit fallbacks that never own an Agent.
pub fn HerdrReporter::release(self : HerdrReporter) -> Unit {
  (self.spawn)(self.bin, [
    "pane",
    "release-agent",
    self.pane,
    "--source",
    "cetas",
    "--agent",
    "cetas",
  ])
}

///|
pub impl @posoco.Observer for HerdrReporter with fn on_event(
  self,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted => self.emit(Working)
    // A permission confirm, plan review, or ask_question entered the
    // composed UiPort: the agent is blocked waiting for the user, which is
    // the state herdr's rollup surfaces (and pings) for "needs you".
    @posoco.TurnEvent::UserRequestStarted(prompt~, ..) =>
      self.emit_message(Blocked, prompt)
    // The request left the port; the turn keeps running until a terminal
    // event reports idle.
    @posoco.TurnEvent::UserRequestFinished(..) => self.emit(Working)
    @posoco.TurnEvent::TurnCompleted => self.emit(Idle)
    @posoco.TurnEvent::TurnFailed(_) => self.emit(Idle)
    _ => ()
  }
}

///|
pub extend HerdrReporter with @posoco.Observer::{on_event_at}

///|
/// The spawn seam never raises, so shutdown stays failure-free for the
/// Agent's lifecycle walk.
pub impl @posoco.Lifecycle for HerdrReporter with fn on_shutdown(self) -> Unit {
  self.release()
}

///|
pub extend HerdrReporter with @posoco.Lifecycle::{on_compose, on_start}
