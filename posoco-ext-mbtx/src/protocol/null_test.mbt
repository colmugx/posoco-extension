///|
test "explicit structured null remains distinct from absent structured output" {
  let absent = @protocol.Success(content="empty", structured=None)
  let present = @protocol.Success(content="null", structured=Some(Json::null()))
  assert_eq(@protocol.Outcome::from_json(absent.to_json()), absent)
  assert_eq(@protocol.Outcome::from_json(present.to_json()), present)
}
