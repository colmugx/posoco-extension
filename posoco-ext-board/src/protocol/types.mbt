///|
pub(all) struct BoardHello {
  last_seq : Int64
  protocol_version : Int
} derive(Eq, Debug)

///|
pub extend BoardHello with Eq::{equal, not_equal}

///|
pub extend BoardHello with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) struct BoardClientCommand {
  command_id : String
  name : String
  expected_revision : Int64
  args : Json
} derive(Eq, Debug)

///|
pub extend BoardClientCommand with Eq::{equal, not_equal}

///|
pub extend BoardClientCommand with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) struct BoardCommandResult {
  command_id : String
  accepted : Bool
  error : String?
  current_revision : Int64?
} derive(Eq, Debug)

///|
pub extend BoardCommandResult with Eq::{equal, not_equal}

///|
pub extend BoardCommandResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Protocol-owned attribution. This intentionally does not expose Posoco's
/// EventScope type, keeping the wire surface independent from core internals.
pub(all) struct BoardEventScope {
  session_id : String?
  run_id : String?
  turn_id : String?
} derive(Eq, Debug)

///|
pub extend BoardEventScope with Eq::{equal, not_equal}

///|
pub extend BoardEventScope with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) struct BoardWireEvent {
  seq : Int64
  board_revision : Int64
  kind : String
  scope : BoardEventScope?
  payload : Json
} derive(Eq, Debug)

///|
pub extend BoardWireEvent with Eq::{equal, not_equal}

///|
pub extend BoardWireEvent with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// S0 snapshot is deliberately domain-agnostic. `payload` becomes the typed
/// Board projection once the domain stage lands; transport sequencing stays
/// separate through `last_seq` and `board_revision`.
pub(all) struct BoardSnapshot {
  protocol_version : Int
  last_seq : Int64
  board_revision : Int64
  payload : Json
} derive(Eq, Debug)

///|
pub extend BoardSnapshot with Eq::{equal, not_equal}

///|
pub extend BoardSnapshot with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) enum BoardClientFrame {
  Hello(BoardHello)
  Command(BoardClientCommand)
} derive(Eq, Debug)

///|
pub extend BoardClientFrame with Eq::{equal, not_equal}

///|
pub extend BoardClientFrame with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) struct BoardResyncRequired {
  reason : String
  current_seq : Int64
} derive(Eq, Debug)

///|
pub extend BoardResyncRequired with Eq::{equal, not_equal}

///|
pub extend BoardResyncRequired with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) struct BoardServerError {
  code : String
  message : String
} derive(Eq, Debug)

///|
pub extend BoardServerError with Eq::{equal, not_equal}

///|
pub extend BoardServerError with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) enum BoardServerFrame {
  CommandResult(BoardCommandResult)
  Event(BoardWireEvent)
  Snapshot(BoardSnapshot)
  ResyncRequired(BoardResyncRequired)
  ServerError(BoardServerError)
} derive(Eq, Debug)

///|
pub extend BoardServerFrame with Eq::{equal, not_equal}

///|
pub extend BoardServerFrame with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) enum BoardProtocolError {
  InvalidJson(String)
  InvalidFrame(String)
  UnsupportedVersion(expected~ : Int, got~ : Int)
} derive(Eq, Debug)

///|
pub extend BoardProtocolError with Eq::{equal, not_equal}

///|
pub extend BoardProtocolError with @moonbitlang/core/debug.Debug::{to_repr}
