///|
test "memory_logger_records_warn_events" {
  let logger = MemoryLogger::new()
  logger.log({
    level: Warn,
    source: "test",
    code: "warn",
    message: "warned",
    data: None,
  })
  assert_eq(logger.events.length(), 1)
  assert_true(logger.events[0].level == Warn)
}

///|
test "ext_context_warn_emits_log_event" {
  let logger = MemoryLogger::new()
  let ctx = ExtContext::new(logger~)
  ctx.warn(
    source="devkit-test",
    code="devkit.warn",
    message="warned",
    data=Some(Json::string("data")),
  )
  assert_eq(logger.events.length(), 1)
  assert_true(logger.events[0].level == Warn)
  assert_eq(logger.events[0].source, "devkit-test")
  assert_eq(logger.events[0].code, "devkit.warn")
  assert_eq(logger.events[0].message, "warned")
  assert_true(logger.events[0].data == Some(Json::string("data")))
}

///|
test "ext_context_default_is_noop" {
  let ctx = ExtContext::default()
  ctx.info(source="devkit-test", code="noop", message="no-op")
}
