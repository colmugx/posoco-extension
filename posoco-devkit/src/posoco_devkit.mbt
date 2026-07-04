///|
pub(all) enum LogLevel {
  Debug
  Info
  Warn
  Error
} derive(Eq)

///|
pub(all) struct LogEvent {
  level : LogLevel
  source : String
  code : String
  message : String
  data : Json?
}

///|
pub(open) trait Logger {
  fn log(Self, event : LogEvent) -> Unit
}
