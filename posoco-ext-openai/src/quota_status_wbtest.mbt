///|
/// CodexQuotaStatus publication over the devkit bus.

///|
priv struct QuotaBusRecorder {
  events : Array[@devkit.BusEvent]
}

///|
impl @devkit.BusSubscriber for QuotaBusRecorder with fn on_bus_event(
  self : QuotaBusRecorder,
  event : @devkit.BusEvent,
) -> Unit {
  self.events.push(event)
}

///|
fn tk_quota_assistant() -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("done")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
}

///|
fn tk_quota_status(
  bus : @devkit.EventBus,
  tracker : CodexQuotaTracker,
) -> CodexQuotaStatus {
  CodexQuotaStatus(bus=Some(bus), tracker=Some(tracker))
}

///|
test "codex quota status publishes windows and unregisters vanished ones" {
  let bus = @devkit.EventBus::EventBus()
  let recorder = QuotaBusRecorder::{ events: [], }
  bus.subscribe(recorder as &@devkit.BusSubscriber)
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  let status = tk_quota_status(bus, tracker)
  // Before any capture, a model response publishes nothing.
  @posoco.Observer::on_event(
    status,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_quota_assistant(),
      usage=None,
    ),
  )
  assert_eq(recorder.events.length(), 0)
  // A snapshot with both windows registers two segments; 20% left colors as
  // a warning while 37.5% left stays uncolored.
  tracker.capture_readings([
    {
      window: "5h",
      used_percent: Some(62.5),
      amount: None,
      available: None,
      reset_at_ms: Some(1757000180000L),
      fetched_at_ms: 1757000000000L,
    },
    {
      window: "weekly",
      used_percent: Some(80.0),
      amount: None,
      available: None,
      reset_at_ms: None,
      fetched_at_ms: 1757000000000L,
    },
  ])
  @posoco.Observer::on_event(
    status,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_quota_assistant(),
      usage=None,
    ),
  )
  assert_eq(recorder.events.length(), 2)
  assert_eq(
    @devkit.decode_status_op(recorder.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="5h",
        label=None,
        priority=45,
        value=Some("37.5% left"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(recorder.events[1]),
    Some(
      @devkit.StatusOp::Register(
        segment="weekly",
        label=None,
        priority=45,
        value=Some("20% left"),
        color=Some("warning"),
      ),
    ),
  )
  // An unchanged snapshot stays silent even across unrelated providers.
  @posoco.Observer::on_event(
    status,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_quota_assistant(),
      usage=None,
    ),
  )
  assert_eq(recorder.events.length(), 2)
  // A later snapshot that lost the 5h window republishes the surviving
  // weekly segment and unregisters the vanished one.
  tracker.capture_readings([
    {
      window: "weekly",
      used_percent: Some(80.0),
      amount: None,
      available: None,
      reset_at_ms: None,
      fetched_at_ms: 1757000000000L,
    },
  ])
  @posoco.Observer::on_event(
    status,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_quota_assistant(),
      usage=None,
    ),
  )
  assert_eq(recorder.events.length(), 4)
  assert_eq(
    @devkit.decode_status_op(recorder.events[2]),
    Some(
      @devkit.StatusOp::Register(
        segment="weekly",
        label=None,
        priority=45,
        value=Some("20% left"),
        color=Some("warning"),
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(recorder.events[3]),
    Some(@devkit.StatusOp::Unregister(segment="5h")),
  )
}

///|
test "codex quota status colors exhausted windows as errors" {
  let bus = @devkit.EventBus::EventBus()
  let recorder = QuotaBusRecorder::{ events: [], }
  bus.subscribe(recorder as &@devkit.BusSubscriber)
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  tracker.capture_readings([
    {
      window: "5h",
      used_percent: Some(100.0),
      amount: None,
      available: None,
      reset_at_ms: None,
      fetched_at_ms: 1757000000000L,
    },
  ])
  let status = tk_quota_status(bus, tracker)
  @posoco.Observer::on_event(
    status,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_quota_assistant(),
      usage=None,
    ),
  )
  assert_eq(recorder.events.length(), 1)
  assert_eq(
    @devkit.decode_status_op(recorder.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="5h",
        label=None,
        priority=45,
        value=Some("0% left"),
        color=Some("error"),
      ),
    ),
  )
}

///|
test "codex quota status publishes at compose" {
  let bus = @devkit.EventBus::EventBus()
  let recorder = QuotaBusRecorder::{ events: [], }
  bus.subscribe(recorder as &@devkit.BusSubscriber)
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  tracker.capture_readings([
    {
      window: "5h",
      used_percent: Some(62.5),
      amount: None,
      available: None,
      reset_at_ms: Some(1757000180000L),
      fetched_at_ms: 1757000000000L,
    },
  ])
  let status = tk_quota_status(bus, tracker)
  @posoco.Lifecycle::on_compose(
    status,
    @posoco.tk_view(
      requires=[],
      model=@posoco.ScriptedModel([]) as &@posoco.ModelPort,
      ui=@posoco.NoopUiPort() as &@posoco.UiPort,
    ),
  )
  assert_eq(recorder.events.length(), 1)
  assert_eq(
    @devkit.decode_status_op(recorder.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="5h",
        label=None,
        priority=45,
        value=Some("37.5% left"),
        color=None,
      ),
    ),
  )
}

///|
test "codex quota status reports its manifest and shares the default tracker" {
  let tracker = codex_shared_quota_tracker()
  assert_eq(
    codex_shared_quota_tracker().snapshots().length(),
    tracker.snapshots().length(),
  )
  let status = CodexQuotaStatus(
    tracker=Some(CodexQuotaTracker::CodexQuotaTracker()),
  )
  assert_eq(@posoco.Extension::extension_id(status), "posoco_ext_openai_quota")
  assert_eq(@posoco.Extension::manifest(status).id, "posoco_ext_openai_quota")
  assert_eq(@posoco.Extension::manifest(status).lifecycle.length(), 1)
}

///|
fn tk_quota_provider_event(provider_id : String) -> @devkit.BusEvent {
  {
    source: "posoco_ext_llm",
    topic: "provider",
    data: Json::object(
      Map::from_array([("provider_id", Json::string(provider_id))]),
    ),
  }
}

///|
test "codex quota status hides windows when another provider activates" {
  let bus = @devkit.EventBus::EventBus()
  let recorder = QuotaBusRecorder::{ events: [], }
  bus.subscribe(recorder as &@devkit.BusSubscriber)
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  tracker.capture_readings([
    {
      window: "5h",
      used_percent: Some(62.5),
      amount: None,
      available: None,
      reset_at_ms: Some(1757000180000L),
      fetched_at_ms: 1757000000000L,
    },
    {
      window: "weekly",
      used_percent: Some(80.0),
      amount: None,
      available: None,
      reset_at_ms: None,
      fetched_at_ms: 1757000000000L,
    },
  ])
  let status = tk_quota_status(bus, tracker)
  @posoco.Lifecycle::on_compose(
    status,
    @posoco.tk_view(
      requires=[],
      model=@posoco.ScriptedModel([]) as &@posoco.ModelPort,
      ui=@posoco.NoopUiPort() as &@posoco.UiPort,
    ),
  )
  assert_eq(recorder.events.length(), 2)
  // A hand-built router event (the frozen provider contract) unregisters
  // both windows; the recorder also records the provider event itself, and
  // the queued unregister batch drains before publish returns.
  bus.publish(tk_quota_provider_event("deepseek"))
  assert_eq(recorder.events.length(), 5)
  assert_eq(@devkit.decode_status_op(recorder.events[2]), None)
  assert_eq(
    @devkit.decode_status_op(recorder.events[3]),
    Some(@devkit.StatusOp::Unregister(segment="5h")),
  )
  assert_eq(
    @devkit.decode_status_op(recorder.events[4]),
    Some(@devkit.StatusOp::Unregister(segment="weekly")),
  )
  // A provider payload without a usable provider_id is ignored.
  bus.publish({
    source: "posoco_ext_llm",
    topic: "provider",
    data: Json::null(),
  })
  assert_eq(recorder.events.length(), 6)
  // The suppression gate: the other provider's responses republish nothing.
  @posoco.Observer::on_event(
    status,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_quota_assistant(),
      usage=None,
    ),
  )
  assert_eq(recorder.events.length(), 6)
}

///|
test "codex quota status re-shows windows when codex re-activates" {
  let bus = @devkit.EventBus::EventBus()
  let recorder = QuotaBusRecorder::{ events: [], }
  bus.subscribe(recorder as &@devkit.BusSubscriber)
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  tracker.capture_readings([
    {
      window: "5h",
      used_percent: Some(62.5),
      amount: None,
      available: None,
      reset_at_ms: Some(1757000180000L),
      fetched_at_ms: 1757000000000L,
    },
    {
      window: "weekly",
      used_percent: Some(80.0),
      amount: None,
      available: None,
      reset_at_ms: None,
      fetched_at_ms: 1757000000000L,
    },
  ])
  let status = tk_quota_status(bus, tracker)
  @posoco.Lifecycle::on_compose(
    status,
    @posoco.tk_view(
      requires=[],
      model=@posoco.ScriptedModel([]) as &@posoco.ModelPort,
      ui=@posoco.NoopUiPort() as &@posoco.UiPort,
    ),
  )
  assert_eq(recorder.events.length(), 2)
  bus.publish(tk_quota_provider_event("deepseek"))
  assert_eq(recorder.events.length(), 5)
  // Codex re-activates: the cleared last-snapshot counts as a change, so the
  // windows re-register in remaining-quota spelling (the openai event itself
  // is recorded at index 5, the queued registers follow).
  bus.publish(tk_quota_provider_event("openai"))
  assert_eq(recorder.events.length(), 8)
  assert_eq(
    @devkit.decode_status_op(recorder.events[6]),
    Some(
      @devkit.StatusOp::Register(
        segment="5h",
        label=None,
        priority=45,
        value=Some("37.5% left"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(recorder.events[7]),
    Some(
      @devkit.StatusOp::Register(
        segment="weekly",
        label=None,
        priority=45,
        value=Some("20% left"),
        color=Some("warning"),
      ),
    ),
  )
}
