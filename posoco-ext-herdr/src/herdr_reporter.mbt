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

///|
priv enum HerdrAgentState {
  Working
  Idle
}

///|
fn HerdrAgentState::cli_value(self : HerdrAgentState) -> String {
  match self {
    Working => "working"
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
  { pane: cfg.pane, bin: cfg.bin, spawn: herdr_spawn_report }
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
pub impl @posoco.Observer for HerdrReporter with fn on_event(
  self,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted => self.emit(Working)
    @posoco.TurnEvent::TurnCompleted => self.emit(Idle)
    @posoco.TurnEvent::TurnFailed(_) => self.emit(Idle)
    _ => ()
  }
}

///|
/// Single-quote an argument for the `sh -c` command line used by the native
/// backend. `'` inside the value is closed, escaped, and reopened.
fn herdr_shell_quote(s : String) -> String {
  "'" + s.replace(old="'", new="'\\''") + "'"
}
