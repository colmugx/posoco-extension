///|
fn mutate_payload(payload : Json) -> Unit {
  guard payload is Json::Object(fields) else { abort("expected object") }
  guard fields.get("nested") is Some(Json::Array(items)) else {
    abort("expected nested array")
  }
  items[0] = Json::string("mutated")
}

///|
async test "headless telemetry and subscriber frames cannot mutate retained stream" {
  let backend = @backend.BoardBackend()
  let first = backend.subscribe(0L, true)
  let second = backend.subscribe(0L, true)
  let input : Json = { "nested": ["original"] }
  let returned = backend.publish_telemetry(
    board_revision=0L,
    kind="test",
    payload=input,
  )
  mutate_payload(input)
  mutate_payload(returned.payload)
  guard first.next() is @protocol.Event(event) else { fail("expected event") }
  mutate_payload(event.payload)
  guard second.next() is @protocol.Event(other) else { fail("expected event") }
  assert_eq(other.payload, { "nested": ["original"] })
  let history = backend.event_history()
  assert_eq(history[0].payload, { "nested": ["original"] })
  mutate_payload(history[0].payload)
  assert_eq(backend.event_history()[0].payload, { "nested": ["original"] })
  backend.unsubscribe(first)
  backend.unsubscribe(second)
}
