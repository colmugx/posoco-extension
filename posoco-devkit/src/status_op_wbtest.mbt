///|
/// Whitebox tests for the status-bridge protocol: publish/decode
/// round-trips, the pinned wire shapes, and decode tolerance.

///|
priv struct EventCapture {
  events : Array[BusEvent]
}

///|
fn EventCapture::EventCapture() -> EventCapture {
  { events: [], }
}

///|
impl BusSubscriber for EventCapture with fn on_bus_event(
  self : EventCapture,
  event : BusEvent,
) -> Unit {
  self.events.push(event)
}

///|
fn status_event(data : Json) -> BusEvent {
  { source: "ext", topic: STATUS_TOPIC, data, }
}

///|
test "status register round-trips through the bus" {
  let bus = EventBus()
  let capture = EventCapture()
  bus.subscribe(capture)
  publish_status_register(
    bus,
    source="posoco_ext_plan",
    segment="plan",
    label="mode",
    priority=10,
    value="on",
  )
  assert_eq(capture.events.length(), 1)
  assert_eq(capture.events[0].source, "posoco_ext_plan")
  assert_eq(capture.events[0].topic, "status")
  assert_eq(
    decode_status_op(capture.events[0]),
    Some(
      Register(
        segment="plan",
        label=Some("mode"),
        priority=10,
        value=Some("on"),
        color=None,
      ),
    ),
  )
}

///|
test "register with no optionals decodes to defaults" {
  let bus = EventBus()
  let capture = EventCapture()
  bus.subscribe(capture)
  publish_status_register(bus, source="ext", segment="ttft")
  assert_eq(
    decode_status_op(capture.events[0]),
    Some(
      Register(segment="ttft", label=None, priority=0, value=None, color=None),
    ),
  )
}

///|
test "register partial optionals decode field-by-field" {
  let label_only = decode_status_op(
    status_event(
      Json::object({
        "op": Json::string("register"),
        "segment": Json::string("tok"),
        "label": Json::string("tokens"),
      }),
    ),
  )
  let value_only = decode_status_op(
    status_event(
      Json::object({
        "op": Json::string("register"),
        "segment": Json::string("cache"),
        "priority": Json::number(40.0),
        "value": Json::string("hit"),
      }),
    ),
  )
  assert_eq(
    label_only,
    Some(
      Register(
        segment="tok",
        label=Some("tokens"),
        priority=0,
        value=None,
        color=None,
      ),
    ),
  )
  assert_eq(
    value_only,
    Some(
      Register(
        segment="cache",
        label=None,
        priority=40,
        value=Some("hit"),
        color=None,
      ),
    ),
  )
}

///|
test "status update round-trips through the bus" {
  let bus = EventBus()
  let capture = EventCapture()
  bus.subscribe(capture)
  publish_status_update(bus, source="ext", segment="session", value="s_42")
  assert_eq(
    decode_status_op(capture.events[0]),
    Some(Update(segment="session", value="s_42")),
  )
}

///|
test "status unregister round-trips through the bus" {
  let bus = EventBus()
  let capture = EventCapture()
  bus.subscribe(capture)
  publish_status_unregister(bus, source="ext", segment="plan")
  assert_eq(
    decode_status_op(capture.events[0]),
    Some(Unregister(segment="plan")),
  )
}

///|
test "wire payloads have the pinned shapes" {
  let bus = EventBus()
  let capture = EventCapture()
  bus.subscribe(capture)
  publish_status_register(
    bus,
    source="ext",
    segment="plan",
    label="mode",
    priority=10,
    value="on",
  )
  publish_status_register(bus, source="ext", segment="ttft")
  publish_status_update(bus, source="ext", segment="plan", value="off")
  publish_status_unregister(bus, source="ext", segment="plan")
  publish_status_register(bus, source="ext", segment="plan", color="warning")
  json_inspect(capture.events[0].data, content={
    "op": "register",
    "segment": "plan",
    "priority": 10,
    "label": "mode",
    "value": "on",
  })
  json_inspect(capture.events[1].data, content={
    "op": "register",
    "segment": "ttft",
    "priority": 0,
  })
  json_inspect(capture.events[2].data, content={
    "op": "update",
    "segment": "plan",
    "value": "off",
  })
  json_inspect(capture.events[3].data, content={
    "op": "unregister",
    "segment": "plan",
  })
  json_inspect(capture.events[4].data, content={
    "op": "register",
    "segment": "plan",
    "priority": 0,
    "color": "warning",
  })
}

///|
test "decoded ops snapshot" {
  debug_inspect(
    decode_status_op(
      status_event(
        Json::object({
          "op": Json::string("update"),
          "segment": Json::string("session"),
          "value": Json::string("s_42"),
        }),
      ),
    ),
    content=(
      #|Some(Update(segment="session", value="s_42"))
    ),
  )
}

///|
test "decode rejects wrong topic and non-object payloads" {
  let good_data = Json::object({
    "op": Json::string("unregister"),
    "segment": Json::string("plan"),
  })
  assert_true(
    decode_status_op({
      source: "ext",
      topic: "tool_exemptions",
      data: good_data,
    })
    is None,
  )
  assert_true(decode_status_op(status_event(Json::null())) is None)
  assert_true(decode_status_op(status_event(Json::array([]))) is None)
}

///|
test "decode rejects missing or unknown op" {
  assert_true(
    decode_status_op(
      status_event(Json::object({ "segment": Json::string("plan") })),
    )
    is None,
  )
  assert_true(
    decode_status_op(
      status_event(
        Json::object({
          "op": Json::string("shrink"),
          "segment": Json::string("plan"),
        }),
      ),
    )
    is None,
  )
  assert_true(
    decode_status_op(status_event(Json::object({ "op": Json::number(1.0) })))
    is None,
  )
}

///|
test "decode rejects malformed register payloads" {
  assert_true(
    decode_status_op(
      status_event(
        Json::object({
          "op": Json::string("register"),
          "priority": Json::number(10.0),
        }),
      ),
    )
    is None,
  )
  assert_true(
    decode_status_op(
      status_event(
        Json::object({
          "op": Json::string("register"),
          "segment": Json::string("plan"),
          "label": Json::number(1.0),
        }),
      ),
    )
    is None,
  )
  assert_true(
    decode_status_op(
      status_event(
        Json::object({
          "op": Json::string("register"),
          "segment": Json::string("plan"),
          "value": Json::boolean(true),
        }),
      ),
    )
    is None,
  )
}

///|
test "decode rejects malformed update and unregister payloads" {
  assert_true(
    decode_status_op(
      status_event(
        Json::object({
          "op": Json::string("update"),
          "segment": Json::string("plan"),
        }),
      ),
    )
    is None,
  )
  assert_true(
    decode_status_op(
      status_event(
        Json::object({
          "op": Json::string("unregister"),
          "segment": Json::number(80.0),
        }),
      ),
    )
    is None,
  )
}

///|
test "priority decodes leniently: absent or non-numeric becomes 0" {
  let absent = decode_status_op(
    status_event(
      Json::object({
        "op": Json::string("register"),
        "segment": Json::string("plan"),
      }),
    ),
  )
  let string_priority = decode_status_op(
    status_event(
      Json::object({
        "op": Json::string("register"),
        "segment": Json::string("plan"),
        "priority": Json::string("high"),
      }),
    ),
  )
  let expected = Some(
    Register(segment="plan", label=None, priority=0, value=None, color=None),
  )
  assert_eq(absent, expected)
  assert_eq(string_priority, expected)
}

///|
test "publishing status ops with no subscriber is a silent no-op" {
  let bus = EventBus()
  publish_status_register(bus, source="ext", segment="plan", value="on")
  publish_status_update(bus, source="ext", segment="plan", value="off")
  publish_status_unregister(bus, source="ext", segment="plan")
  assert_eq(bus.subscriber_count(), 0)
  assert_eq(bus.pending.length(), 0)
}

///|
test "status register color round-trips through the bus" {
  let bus = EventBus()
  let capture = EventCapture()
  bus.subscribe(capture)
  publish_status_register(bus, source="ext", segment="plan", color="accent")
  assert_eq(
    decode_status_op(capture.events[0]),
    Some(
      Register(
        segment="plan",
        label=None,
        priority=0,
        value=None,
        color=Some("accent"),
      ),
    ),
  )
  publish_status_register(bus, source="ext", segment="plan", color="sparkly")
  assert_eq(
    decode_status_op(capture.events[1]),
    Some(
      Register(
        segment="plan",
        label=None,
        priority=0,
        value=None,
        color=Some("sparkly"),
      ),
    ),
  )
}

///|
test "decode rejects present-but-non-String color" {
  assert_true(
    decode_status_op(
      status_event(
        Json::object({
          "op": Json::string("register"),
          "segment": Json::string("plan"),
          "color": Json::number(3.0),
        }),
      ),
    )
    is None,
  )
  assert_eq(
    decode_status_op(
      status_event(
        Json::object({
          "op": Json::string("register"),
          "segment": Json::string("plan"),
        }),
      ),
    ),
    Some(
      Register(segment="plan", label=None, priority=0, value=None, color=None),
    ),
  )
}

///|
test "color role vocabulary is closed and exact" {
  assert_eq(status_color_roles(), [
    "accent", "warning", "error", "success", "info", "muted",
  ])
  for role in status_color_roles() {
    assert_true(is_status_color_role(role))
  }
  assert_false(is_status_color_role("sparkly"))
  assert_false(is_status_color_role(""))
  assert_false(is_status_color_role("ACCENT"))
}
