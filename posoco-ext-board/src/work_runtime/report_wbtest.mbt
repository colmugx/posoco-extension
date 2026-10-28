///|
test "work report needs an object with non-empty outcome and summary" {
  assert_true(validate_work_report(Json::object({
    "outcome": Json::string("done"),
    "summary": Json::string("it works"),
  })) is Ok(_))
  assert_true(validate_work_report(Json::array([])) is Err(_))
  assert_true(validate_work_report(Json::object({
    "outcome": Json::string(""),
    "summary": Json::string("it works"),
  })) is Err(_))
  assert_true(validate_work_report(Json::object({
    "outcome": Json::string("  "),
    "summary": Json::string("it works"),
  })) is Err(_))
  assert_true(validate_work_report(Json::object({
    "outcome": Json::string("done"),
  })) is Err(_))
  assert_true(
    validate_work_report(Json::object({
      "outcome": Json::string("done"),
      "summary": Json::null(),
    }))
    is Err(_),
  )
}

///|
test "minimal review report fills a readable fallback for a blank result" {
  let report = match minimal_review_report("  ") {
    Object(fields) => fields
    _ => fail("minimal report must be an object")
  }
  assert_eq(report.get("outcome"), Some(Json::string("Work completed.")))
  assert_eq(report.get("summary"), Some(Json::string("Work completed.")))
  match report.get("changes") {
    Some(Array(items)) => assert_eq(items.length(), 0)
    _ => fail("minimal report must list changes explicitly")
  }
  let detailed = match minimal_review_report(" evidence collected ") {
    Object(fields) => fields
    _ => fail("minimal report must be an object")
  }
  assert_eq(
    detailed.get("outcome"),
    Some(Json::string("evidence collected")),
  )
}
