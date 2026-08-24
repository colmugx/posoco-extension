///|
pub(all) enum LogLevel {
  Debug
  Info
  Warn
  Error
} derive(Eq, Debug)

///|
pub(all) struct LogEvent {
  level : LogLevel
  source : String
  code : String
  message : String
  data : Json?
} derive(Debug)

///|
pub(open) trait Logger {
  fn log(Self, event : LogEvent) -> Unit
}
