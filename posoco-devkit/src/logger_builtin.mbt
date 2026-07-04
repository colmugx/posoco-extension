///|
pub(all) struct NoopLogger {}

///|
pub impl Logger for NoopLogger with fn log(_self, _event : LogEvent) -> Unit {
  ()
}

///|
pub(all) struct MemoryLogger {
  events : Array[LogEvent]
}

///|
pub fn MemoryLogger::new() -> MemoryLogger {
  { events: [] }
}

///|
pub impl Logger for MemoryLogger with fn log(self, event) -> Unit {
  self.events.push(event)
}
