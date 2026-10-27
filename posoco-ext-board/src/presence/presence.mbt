///|
/// One-root projection of a Board's activity. Hosts map this to OSC 7501,
/// herdr, a statusbar or a header; the Board owns the aggregation rules.
pub(all) enum BoardPresenceState {
  Idle
  Working
  Blocked
} derive(Eq, Debug)

///|
pub extend BoardPresenceState with Eq::{equal, not_equal}

///|
pub extend BoardPresenceState with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub struct BoardPresence {
  state : BoardPresenceState
  running : Int32
  waiting_input : Int32
  attention : Int32
  message : String?
} derive(Eq, Debug)

///|
pub extend BoardPresence with Eq::{equal, not_equal}

///|
pub extend BoardPresence with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn BoardPresence::project(
  running~ : Int32,
  waiting_input~ : Int32,
  attention~ : Int32,
) -> BoardPresence {
  let running = running.max(0)
  let waiting_input = waiting_input.max(0)
  let attention = attention.max(0)
  if waiting_input > 0 {
    {
      state: Blocked,
      running,
      waiting_input,
      attention,
      message: Some("Board: waiting for your response"),
    }
  } else if running > 0 || attention > 0 {
    {
      state: Working,
      running,
      waiting_input,
      attention,
      message: Some(
        if attention > 0 {
          "Board: attention needed"
        } else {
          "Board: " + running.to_string() + " running"
        },
      ),
    }
  } else {
    { state: Idle, running: 0, waiting_input: 0, attention: 0, message: None, }
  }
}

///|
pub fn BoardPresence::to_json(self : BoardPresence) -> Json {
  Json::object({
    "state": Json::string(
      match self.state {
        Idle => "idle"
        Working => "working"
        Blocked => "blocked"
      },
    ),
    "running": Json::number(self.running.to_double()),
    "waiting_input": Json::number(self.waiting_input.to_double()),
    "attention": Json::number(self.attention.to_double()),
    "message": match self.message {
      Some(message) => Json::string(message)
      None => Json::null()
    },
  })
}
