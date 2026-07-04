///|
pub(all) struct XlogLogger {}

///|
pub fn XlogLogger::new() -> XlogLogger {
  XlogLogger::{  }
}

///|
pub fn context() -> @devkit.ExtContext {
  @devkit.ExtContext::new(logger=XlogLogger::new())
}

///|
pub impl @devkit.Logger for XlogLogger with fn log(
  _self,
  event : @devkit.LogEvent,
) -> Unit {
  match event.level {
    Debug => write_xlog_event(@xlog.debug(category=event.source), event)
    Info => write_xlog_event(@xlog.info(category=event.source), event)
    Warn => write_xlog_event(@xlog.warn(category=event.source), event)
    Error => write_xlog_event(@xlog.error(category=event.source), event)
  }
}

///|
fn write_xlog_event(event : @xlog.Event?, log_event : @devkit.LogEvent) -> Unit {
  match event {
    Some(e) => {
      e.write_object_begin()
      e.write_object_field("code", log_event.code)
      e.write_object_field("message", log_event.message)
      match log_event.data {
        Some(data) => e.write_object_field("data", data)
        None => ()
      }
      e.write_object_end()
    }
    None => ()
  }
}
