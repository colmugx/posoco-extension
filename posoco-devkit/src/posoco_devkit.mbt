///|
#derive(Eq, Debug)
pub(all) enum LogLevel {
  Debug
  Info
  Warn
  Error
}

///|
pub extend LogLevel with Eq::{not_equal, equal}

///|
pub extend LogLevel with @moonbitlang/core/debug.Debug::{to_repr}

///|
#derive(Debug)
pub(all) struct LogEvent {
  level : LogLevel
  source : String
  code : String
  message : String
  data : Json?
}

///|
pub extend LogEvent with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(open) trait Logger {
  fn log(Self, event : LogEvent) -> Unit
}
