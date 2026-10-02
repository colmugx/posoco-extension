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
/// Status ops published by the codex publisher (its own source only), so
/// assertions stay readable when the router or other peers also publish.
fn codex_status_ops(recorder : QuotaBusRecorder) -> Array[@devkit.StatusOp] {
  let ops : Array[@devkit.StatusOp] = []
  for event in recorder.events {
    if event.source == "posoco_ext_openai" {
      match @devkit.decode_status_op(event) {
        Some(op) => ops.push(op)
        None => ()
      }
    }
  }
  ops
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

///|
/// Startup regression, end to end: the agent composes with an empty tracker,
/// then the provider refresh's usage probe fills it — before any chat. The
/// capture alone must publish the windows on the bus, and `/status` must
/// report the same percentages without a model response ever arriving.
async test "startup usage probe publishes quota and /status reports it before any chat" {
  let bus = @devkit.EventBus::EventBus()
  let recorder = QuotaBusRecorder::{ events: [], }
  bus.subscribe(recorder as &@devkit.BusSubscriber)
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  let status = tk_quota_status(bus, tracker)
  let slot = @llm.ModelSlot::ModelSlot(
    id="codex-slot",
    label="Codex",
    provider_id="openai",
    model_id="gpt-5-codex",
    port=@posoco.ScriptedModel([]) as &@posoco.ModelPort,
  )
  let source : &@devkit.QuotaSource = tracker
  let router = @llm.RouterModelPort(
    slots=[slot],
    bus=Some(bus),
    extra_quota_sources=Map::from_array([("openai", source)]),
  )
  let view = @posoco.tk_view(
    requires=[],
    model=@posoco.ScriptedModel([]) as &@posoco.ModelPort,
    ui=@posoco.NoopUiPort() as &@posoco.UiPort,
  )
  @posoco.Lifecycle::on_compose(status, view)
  // The router's compose announces the active provider: the publisher is
  // scoped to openai from here on. The tracker is still empty, so nothing
  // is on the bar.
  @posoco.Lifecycle::on_compose(router, view)
  assert_eq(codex_status_ops(recorder).length(), 0)
  // The refresh's usage probe: the real captured endpoint payload parsed by
  // the production parser lands in the tracker. No chat, no model response.
  let readings = expect_codex_usage(
    codex_usage_fixture(),
    fetched_at_ms=1757000000000L,
  )
  tracker.capture_readings(readings)
  let ops = codex_status_ops(recorder)
  assert_eq(ops.length(), 2)
  assert_eq(
    ops[0],
    @devkit.StatusOp::Register(
      segment="5h",
      label=None,
      priority=45,
      value=Some("50.5% left"),
      color=None,
    ),
  )
  assert_eq(
    ops[1],
    @devkit.StatusOp::Register(
      segment="weekly",
      label=None,
      priority=45,
      value=Some("20% left"),
      color=Some("warning"),
    ),
  )
  // /status surfaces the same percentages from the bus cache.
  let outcome = router.invoke("status", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("provider: openai"))
      assert_true(feedback.contains("5h: 50.5% left"))
      assert_true(feedback.contains("weekly: 20% left"))
      match structured {
        Some(Json::Object(fields)) =>
          match fields.get("quota") {
            Some(Json::Object(quota)) => {
              match quota.get("5h") {
                Some(Json::String("50.5% left")) => ()
                _ => fail("structured 5h quota mismatch")
              }
              match quota.get("weekly") {
                Some(Json::String("20% left")) => ()
                _ => fail("structured weekly quota mismatch")
              }
            }
            _ => fail("expected quota object in structured status")
          }
        _ => fail("expected structured status object")
      }
    }
    _ => fail("expected successful status report")
  }
}

///|
/// Shutdown detaches the tracker listener: the process-shared tracker
/// outlives the publisher, and a stale closure must not publish after the
/// agent is gone.
async test "shutdown unsubscribes the publisher from tracker changes" {
  let bus = @devkit.EventBus::EventBus()
  let recorder = QuotaBusRecorder::{ events: [], }
  bus.subscribe(recorder as &@devkit.BusSubscriber)
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  let status = tk_quota_status(bus, tracker)
  @posoco.Lifecycle::on_shutdown(status)
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
  assert_eq(codex_status_ops(recorder).length(), 0)
}

///|
/// A second real-shaped usage payload: later in the window, different
/// percentages, parsed by the production parser like any refresh probe.
fn codex_usage_fixture_later() -> Json {
  {
    "plan_type": "plus",
    "rate_limit": {
      "limit_reached": false,
      "primary_window": {
        "used_percent": 80.0,
        "limit_window_seconds": 18000,
        "reset_at": 1777936568,
      },
      "secondary_window": {
        "used_percent": 90.0,
        "limit_window_seconds": 604800,
        "reset_after_seconds": 316705,
      },
    },
    "credits": { "has_credits": false, "unlimited": false, "balance": "0" },
  }
}

///|
/// Tracker subscriptions are per-registration: two publishers on different
/// buses sharing the process tracker each receive captures, shutting the
/// older one stops only its own notifications, and the surviving bus keeps
/// feeding both the bar and `/status` — all before any chat.
async test "coexisting publishers stay independent across buses and lifetimes" {
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  let bus_a = @devkit.EventBus::EventBus()
  let recorder_a = QuotaBusRecorder::{ events: [], }
  bus_a.subscribe(recorder_a as &@devkit.BusSubscriber)
  let bus_b = @devkit.EventBus::EventBus()
  let recorder_b = QuotaBusRecorder::{ events: [], }
  bus_b.subscribe(recorder_b as &@devkit.BusSubscriber)
  // Older lifetime on bus A, newer on bus B; both watch the same tracker.
  let status_a = tk_quota_status(bus_a, tracker)
  let status_b = tk_quota_status(bus_b, tracker)
  let slot = @llm.ModelSlot::ModelSlot(
    id="codex-slot",
    label="Codex",
    provider_id="openai",
    model_id="gpt-5-codex",
    port=@posoco.ScriptedModel([]) as &@posoco.ModelPort,
  )
  let source : &@devkit.QuotaSource = tracker
  let router_b = @llm.RouterModelPort(
    slots=[slot],
    bus=Some(bus_b),
    extra_quota_sources=Map::from_array([("openai", source)]),
  )
  let view = @posoco.tk_view(
    requires=[],
    model=@posoco.ScriptedModel([]) as &@posoco.ModelPort,
    ui=@posoco.NoopUiPort() as &@posoco.UiPort,
  )
  // bus B's router composes: its provider event scopes the newer publisher
  // to openai, exactly as at startup.
  @posoco.Lifecycle::on_compose(router_b, view)
  // First capture: BOTH buses must see the windows.
  tracker.capture_readings(
    expect_codex_usage(codex_usage_fixture(), fetched_at_ms=1757000000000L),
  )
  assert_eq(codex_status_ops(recorder_a).length(), 2)
  assert_eq(codex_status_ops(recorder_b).length(), 2)
  // /status on the surviving bus reports the captured percentages.
  let first = router_b.invoke("status", Json::null())
  match first {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      assert_true(feedback.contains("5h: 50.5% left"))
      assert_true(feedback.contains("weekly: 20% left"))
    }
    _ => fail("expected successful status report")
  }
  // The older lifetime shuts down: only ITS notifications may stop.
  @posoco.Lifecycle::on_shutdown(status_a)
  // Second capture: bus A stays silent, bus B moves on.
  tracker.capture_readings(
    expect_codex_usage(
      codex_usage_fixture_later(),
      fetched_at_ms=1757000001000L,
    ),
  )
  assert_eq(codex_status_ops(recorder_a).length(), 2)
  let ops_b = codex_status_ops(recorder_b)
  assert_eq(ops_b.length(), 4)
  assert_eq(
    ops_b[2],
    @devkit.StatusOp::Register(
      segment="5h",
      label=None,
      priority=45,
      value=Some("20% left"),
      color=Some("warning"),
    ),
  )
  assert_eq(
    ops_b[3],
    @devkit.StatusOp::Register(
      segment="weekly",
      label=None,
      priority=45,
      value=Some("10% left"),
      color=Some("warning"),
    ),
  )
  // /status on bus B now reports the refreshed percentages.
  let second = router_b.invoke("status", Json::null())
  match second {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("5h: 20% left"))
      assert_true(feedback.contains("weekly: 10% left"))
      match structured {
        Some(Json::Object(fields)) =>
          match fields.get("quota") {
            Some(Json::Object(quota)) =>
              match quota.get("weekly") {
                Some(Json::String("10% left")) => ()
                _ => fail("structured weekly quota did not refresh")
              }
            _ => fail("expected quota object in structured status")
          }
        _ => fail("expected structured status object")
      }
    }
    _ => fail("expected successful status report")
  }
  // The newer lifetime shuts down too: no bus sees further captures.
  @posoco.Lifecycle::on_shutdown(status_b)
  tracker.capture_readings(
    expect_codex_usage(codex_usage_fixture(), fetched_at_ms=1757000002000L),
  )
  assert_eq(codex_status_ops(recorder_a).length(), 2)
  assert_eq(codex_status_ops(recorder_b).length(), 4)
}

///|
/// A stopped publisher is dead. The bus keeps its (unsubscribable)
/// registration, so late provider events must not act for it: no unregisters
/// racing a successor that shares the source, no republish when codex
/// re-activates. A late observer event cannot resurrect it either, and a
/// capture that lands after shutdown stays the successor's alone. Normal
/// compose-time publications are untouched.
async test "stopped publisher ignores late provider and observer events" {
  let bus = @devkit.EventBus::EventBus()
  let recorder = QuotaBusRecorder::{ events: [], }
  bus.subscribe(recorder as &@devkit.BusSubscriber)
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  tracker.capture_readings(
    expect_codex_usage(codex_usage_fixture(), fetched_at_ms=1757000000000L),
  )
  let view = @posoco.tk_view(
    requires=[],
    model=@posoco.ScriptedModel([]) as &@posoco.ModelPort,
    ui=@posoco.NoopUiPort() as &@posoco.UiPort,
  )
  // First lifetime: compose publishes normally, then it stops.
  let status_a = tk_quota_status(bus, tracker)
  @posoco.Lifecycle::on_compose(status_a, view)
  assert_eq(codex_status_ops(recorder).length(), 2)
  @posoco.Lifecycle::on_shutdown(status_a)
  // Successor on the same bus, same shared tracker and source id.
  let status_b = tk_quota_status(bus, tracker)
  @posoco.Lifecycle::on_compose(status_b, view)
  assert_eq(codex_status_ops(recorder).length(), 4)
  // Late non-openai provider event: only the live successor hides its
  // windows; the stopped one must not fire unregisters against the shared
  // source.
  bus.publish(tk_quota_provider_event("deepseek"))
  let ops = codex_status_ops(recorder)
  assert_eq(ops.length(), 6)
  assert_eq(ops[4], @devkit.StatusOp::Unregister(segment="5h"))
  assert_eq(ops[5], @devkit.StatusOp::Unregister(segment="weekly"))
  // Late openai event: only the successor republishes.
  bus.publish(tk_quota_provider_event("openai"))
  let ops = codex_status_ops(recorder)
  assert_eq(ops.length(), 8)
  assert_eq(
    ops[6],
    @devkit.StatusOp::Register(
      segment="5h",
      label=None,
      priority=45,
      value=Some("50.5% left"),
      color=None,
    ),
  )
  assert_eq(
    ops[7],
    @devkit.StatusOp::Register(
      segment="weekly",
      label=None,
      priority=45,
      value=Some("20% left"),
      color=Some("warning"),
    ),
  )
  // A capture after shutdown reaches only the successor's tracker listener.
  tracker.capture_readings(
    expect_codex_usage(
      codex_usage_fixture_later(),
      fetched_at_ms=1757000001000L,
    ),
  )
  assert_eq(codex_status_ops(recorder).length(), 10)
  // A late observer event cannot resurrect the stopped publisher.
  @posoco.Observer::on_event(
    status_a,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_quota_assistant(),
      usage=None,
    ),
  )
  assert_eq(codex_status_ops(recorder).length(), 10)
}
