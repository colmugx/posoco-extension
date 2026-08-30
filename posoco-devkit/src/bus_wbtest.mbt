///|
/// Whitebox tests for the product-level EventBus: delivery order, the
/// fire-and-forget no-op, and reentrant publish queuing.

///|
priv struct RecordingSubscriber {
  id : String
  seen : Array[String]
}

///|
fn RecordingSubscriber::RecordingSubscriber(id : String) -> RecordingSubscriber {
  { id, seen: [], }
}

///|
impl BusSubscriber for RecordingSubscriber with fn on_bus_event(
  self : RecordingSubscriber,
  event : BusEvent,
) -> Unit {
  self.seen.push("\{self.id}:\{event.source}/\{event.topic}")
}

///|
fn bus_event(source : String, topic? : String = "status") -> BusEvent {
  { source, topic, data: Json::null(), }
}

///|
test "events reach every subscriber in registration order" {
  let bus = EventBus()
  let first = RecordingSubscriber("a")
  let second = RecordingSubscriber("b")
  bus.subscribe(first)
  bus.subscribe(second)
  bus.publish(bus_event("ext_one"))
  bus.publish(bus_event("ext_two"))
  assert_eq(first.seen.join(","), "a:ext_one/status,a:ext_two/status")
  assert_eq(second.seen.join(","), "b:ext_one/status,b:ext_two/status")
}

///|
test "publishing with no subscribers is a silent no-op" {
  let bus = EventBus()
  bus.publish(bus_event("ext_one"))
  assert_eq(bus.subscriber_count(), 0)
}

///|
priv struct ReentrantSubscriber {
  mut bus : EventBus?
  seen : Array[String]
}

///|
fn ReentrantSubscriber::ReentrantSubscriber() -> ReentrantSubscriber {
  { bus: None, seen: [], }
}

///|
impl BusSubscriber for ReentrantSubscriber with fn on_bus_event(
  self : ReentrantSubscriber,
  event : BusEvent,
) -> Unit {
  self.seen.push(event.source)
  // Reentrant publish: must queue behind the in-flight batch, not recurse.
  if event.source == "outer" {
    match self.bus {
      Some(bus) => bus.publish(bus_event("inner"))
      None => ()
    }
  }
}

///|
test "reentrant publishes queue after the in-flight batch" {
  let bus = EventBus()
  let sub = ReentrantSubscriber()
  bus.subscribe(sub)
  sub.bus = Some(bus)
  bus.publish(bus_event("outer"))
  assert_eq(sub.seen.join(","), "outer,inner")
}

///|
/// Subscribes another subscriber from inside its own handler, to pin down
/// when mid-dispatch registrations take effect.
priv struct RegistrarSubscriber {
  bus : EventBus
  late : &BusSubscriber
}

///|
impl BusSubscriber for RegistrarSubscriber with fn on_bus_event(
  self : RegistrarSubscriber,
  _event : BusEvent,
) -> Unit {
  self.bus.subscribe(self.late)
}

///|
test "subscriber added during dispatch sees the next event onward" {
  let bus = EventBus()
  let late = RecordingSubscriber("late")
  let late_sub : &BusSubscriber = late
  let registrar : RegistrarSubscriber = { bus, late: late_sub, }
  bus.subscribe(registrar)
  bus.publish(bus_event("first"))
  bus.publish(bus_event("second"))
  // "first" dispatched before the late subscription landed;
  // "second" is the first event it sees.
  assert_eq(late.seen.join(","), "late:second/status")
}

///|
/// Queues two reentrant publishes when it sees "outer", so both land in one
/// follow-up batch.
priv struct FanoutSubscriber {
  bus : EventBus
}

///|
impl BusSubscriber for FanoutSubscriber with fn on_bus_event(
  self : FanoutSubscriber,
  event : BusEvent,
) -> Unit {
  if event.source == "outer" {
    self.bus.publish(bus_event("b_one"))
    self.bus.publish(bus_event("b_two"))
  }
}

///|
/// Subscribes `late` when it sees "b_one" — mid-batch, with "b_two" still
/// queued behind it in the same batch.
priv struct RegisterOnBOne {
  bus : EventBus
  late : &BusSubscriber
}

///|
impl BusSubscriber for RegisterOnBOne with fn on_bus_event(
  self : RegisterOnBOne,
  event : BusEvent,
) -> Unit {
  if event.source == "b_one" {
    self.bus.subscribe(self.late)
  }
}

///|
test "registration mid-batch waits for the next batch" {
  let bus = EventBus()
  let late = RecordingSubscriber("late")
  let late_sub : &BusSubscriber = late
  bus.subscribe(FanoutSubscriber::{ bus, })
  bus.subscribe(RegisterOnBOne::{ bus, late: late_sub, })
  bus.publish(bus_event("outer"))
  // Batch 2 = [b_one, b_two]; late subscribed during b_one, so the
  // batch-2 snapshot must not include it: "b_two" is not delivered.
  assert_eq(late.seen.join(","), "")
  bus.publish(bus_event("after"))
  assert_eq(late.seen.join(","), "late:after/status")
}
