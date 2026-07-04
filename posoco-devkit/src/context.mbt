///|
pub(all) struct ExtContext {
  logger : &Logger
}

///|
pub fn ExtContext::default() -> ExtContext {
  { logger: NoopLogger::{  } }
}

///|
pub fn ExtContext::new(logger? : &Logger = NoopLogger::{  }) -> ExtContext {
  { logger, }
}

///|
pub fn ExtContext::log(self : ExtContext, event : LogEvent) -> Unit {
  let read_logger = @reader.asks(fn(env : ExtContext) { env.logger })
  let logger = @reader.Reader::run(read_logger, self)
  logger.log(event)
}

///|
pub fn ExtContext::debug(
  self : ExtContext,
  source~ : String,
  code~ : String,
  message~ : String,
  data? : Json? = None,
) -> Unit {
  self.log({ level: Debug, source, code, message, data })
}

///|
pub fn ExtContext::info(
  self : ExtContext,
  source~ : String,
  code~ : String,
  message~ : String,
  data? : Json? = None,
) -> Unit {
  self.log({ level: Info, source, code, message, data })
}

///|
pub fn ExtContext::warn(
  self : ExtContext,
  source~ : String,
  code~ : String,
  message~ : String,
  data? : Json? = None,
) -> Unit {
  self.log({ level: Warn, source, code, message, data })
}

///|
pub fn ExtContext::error(
  self : ExtContext,
  source~ : String,
  code~ : String,
  message~ : String,
  data? : Json? = None,
) -> Unit {
  self.log({ level: Error, source, code, message, data })
}
