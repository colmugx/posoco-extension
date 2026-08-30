///|
pub(all) struct ExtContext {
  logger : &Logger
}

///|
pub fn ExtContext::default() -> ExtContext {
  ExtContext::ExtContext()
}

///|
pub fn ExtContext::ExtContext(
  logger? : &Logger = NoopLogger::{ },
) -> ExtContext {
  { logger, }
}

///|
pub fn ExtContext::log(self : ExtContext, event : LogEvent) -> Unit {
  self.logger.log(event)
}

///|
fn ExtContext::log_at(
  self : ExtContext,
  level : LogLevel,
  source~ : String,
  code~ : String,
  message~ : String,
  data? : Json? = None,
) -> Unit {
  self.log({ level, source, code, message, data, })
}

///|
pub fn ExtContext::debug(
  self : ExtContext,
  source~ : String,
  code~ : String,
  message~ : String,
  data? : Json? = None,
) -> Unit {
  self.log_at(Debug, source~, code~, message~, data~)
}

///|
pub fn ExtContext::info(
  self : ExtContext,
  source~ : String,
  code~ : String,
  message~ : String,
  data? : Json? = None,
) -> Unit {
  self.log_at(Info, source~, code~, message~, data~)
}

///|
pub fn ExtContext::warn(
  self : ExtContext,
  source~ : String,
  code~ : String,
  message~ : String,
  data? : Json? = None,
) -> Unit {
  self.log_at(Warn, source~, code~, message~, data~)
}

///|
pub fn ExtContext::error(
  self : ExtContext,
  source~ : String,
  code~ : String,
  message~ : String,
  data? : Json? = None,
) -> Unit {
  self.log_at(Error, source~, code~, message~, data~)
}
