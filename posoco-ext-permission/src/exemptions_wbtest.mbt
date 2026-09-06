///|
/// Wire-format contract for the `tool_exemptions` payload this gate parses.

///|
test "parse rejects malformed payloads" {
  assert_true(parse_tool_exemptions(Json::null()) is None)
  assert_true(
    parse_tool_exemptions(Json::object({ "tools": Json::string("x") })) is None,
  )
  assert_true(parse_tool_exemptions(Json::array([])) is None)
  assert_true(
    parse_tool_exemptions(
      Json::object({ "tools": Json::array([Json::null()]) }),
    )
    is None,
  )
}
