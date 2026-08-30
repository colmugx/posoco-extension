///|
/// EventBus: a product-level, cross-extension pub/sub channel.
///
/// Posoco's core observer stream is core-owned by design (event emission is
/// deliberately NOT exposed through `CompositionView`), so extensions that
/// want to notify peers — a status bar learning a sprint's progress, a
/// cache reporting its hit rate — need a channel of their own. This bus is
/// that channel: the host (or a product layer such as cetas-core)
/// constructs ONE bus and hands it to every extension constructor that
/// wants to publish or subscribe.
///
/// Contract:
/// - **Fire-and-forget**: publishing with no subscribers is a no-op. An
///   extension may publish unconditionally; when no peer cares, nothing
///   happens and nothing leaks.
/// - **Topics are conventions, not registrations**: every subscriber sees
///   every event and ignores what it does not understand. `topic` is the
///   shared vocabulary (e.g. `"status"` for status-line facts).
/// - **Synchronous and ordered**: subscribers run in registration order,
///   events in publish order. A publish from inside a handler is queued
///   and dispatched after the in-flight batch (no unbounded recursion, no
///   re-entrancy hazards).
/// - **Non-raising**: a handler must not raise; the bus is a notification
///   channel, never an error path.
///
/// # Example
/// ```mbt check
/// test "publish with no subscribers completes silently" {
///   let bus = EventBus::EventBus()
///   bus.publish({
///     source: "posoco_ext_scrum",
///     topic: "status",
///     data: Json::null(),
///   })
///   inspect(bus.subscriber_count(), content="0")
/// }
/// ```
pub struct EventBus {
  subscribers : Array[&BusSubscriber]
  mut pending : Array[BusEvent]
  mut dispatching : Bool
}

///|
/// One notification: `source` identifies the publisher (extension id),
/// `topic` is the shared convention namespace, and `data` is the
/// topic-defined payload.
pub(all) struct BusEvent {
  source : String
  topic : String
  data : Json
} derive(Debug)

///|
/// Subscriber contract: receive every event, ignore what you do not
/// understand. One method, no defaults — a subscriber exists to react.
pub(open) trait BusSubscriber {
  fn on_bus_event(Self, event : BusEvent) -> Unit
}

///|
/// Construct an empty bus. Typically done once per host process.
pub fn EventBus::EventBus() -> EventBus {
  { subscribers: [], pending: [], dispatching: false, }
}

///|
/// Number of live subscribers (observable for tests and diagnostics).
pub fn EventBus::subscriber_count(self : EventBus) -> Int {
  self.subscribers.length()
}

///|
/// Register a subscriber. Registration during an in-flight dispatch takes
/// effect from the next batch onward.
pub fn EventBus::subscribe(
  self : EventBus,
  subscriber : &BusSubscriber,
) -> Unit {
  self.subscribers.push(subscriber)
}

///|
/// Notify every subscriber, in registration order. Reentrant publishes
/// (issued from inside a handler) are queued and dispatched after the
/// in-flight batch completes. Each batch is delivered to a snapshot of the
/// subscriber list taken when the batch starts, so a registration made during
/// a batch starts receiving with the next batch — never mid-batch.
pub fn EventBus::publish(self : EventBus, event : BusEvent) -> Unit {
  self.pending.push(event)
  if self.dispatching {
    return
  }
  self.dispatching = true
  while self.pending.length() > 0 {
    let batch = self.pending
    self.pending = []
    let subscribers = self.subscribers.copy()
    for queued in batch {
      for subscriber in subscribers {
        subscriber.on_bus_event(queued)
      }
    }
  }
  self.dispatching = false
}
