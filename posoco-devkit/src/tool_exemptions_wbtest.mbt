///|
test "publishing exemptions with no subscriber is a silent no-op" {
  let bus = EventBus::EventBus()
  publish_tool_exemptions(bus, source="posoco_ext_plan", tools=[
    "exit_plan_mode",
  ])
  assert_eq(bus.subscriber_count(), 0)
  assert_eq(bus.pending.length(), 0)
}

///|
test "tool exemption report reaches a subscribed gate" {
  let sub = RecordingSubscriber::RecordingSubscriber("gate")
  let bus = EventBus::EventBus()
  bus.subscribe(sub)
  publish_tool_exemptions(bus, source="posoco_ext_plan", tools=[
    "exit_plan_mode", "enter_plan_mode",
  ])
  assert_eq(sub.seen, ["gate:posoco_ext_plan/tool_exemptions"])
}

///|
test "tool exemption payload round-trips" {
  let data = Json::object({
    "tools": Json::array([
      Json::string("exit_plan_mode"),
      Json::string("enter_plan_mode"),
    ]),
  })
  assert_eq(
    parse_tool_exemptions(data),
    Some(["exit_plan_mode", "enter_plan_mode"]),
  )
}

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
