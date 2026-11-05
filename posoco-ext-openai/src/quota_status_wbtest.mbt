///|
/// CodexQuotaStatus publication over the posoco event channel.

///|
/// One test `EventSystem` plus every envelope it delivered: the recorder is a
/// plain listener, so assertions see exactly what a real peer sees (publisher
/// namespace included).
priv struct QuotaRecorder {
  system : @posoco.EventSystem
  events : Array[@posoco.EventEnvelope]
}

///|
fn QuotaRecorder::QuotaRecorder() -> QuotaRecorder {
  let system = @posoco.EventSystem()
  let events : Array[@posoco.EventEnvelope] = []
  match system.subscribe(fn(envelope) { events.push(envelope) }) {
    Ok(_) => ()
    Err(_) => abort("test recorder subscription failed")
  }
  { system, events, }
}

///|
/// The owner-bound capability a host mints with
/// `EventSystem::publisher(owner~)` and hands to the publisher under test.
fn QuotaRecorder::publisher(
  self : QuotaRecorder,
  owner~ : String,
) -> @posoco.Events {
  match self.system.publisher(owner~) {
    Ok(events) => events
    Err(_) => abort("test publisher capability unavailable: " + owner)
  }
}

///|
/// Announce the active provider the way the router does: one
/// `ProviderStatus` from the llm extension's capability.
fn QuotaRecorder::publish_provider(
  self : QuotaRecorder,
  provider_id : String,
) -> Unit {
  ignore(
    self
    .publisher(owner="posoco_ext_llm")
    .publish(@kit_events.ProviderStatus({ provider_id, })),
  )
}

///|
/// Publish unrelated protocol traffic from another extension, the way a peer
/// sharing the channel does.
fn QuotaRecorder::publish_foreign_status(self : QuotaRecorder) -> Unit {
  ignore(
    self
    .publisher(owner="posoco_ext_llm")
    .publish(
      @kit_events.StatusChanged(
        @kit_events.Register(
          segment="model",
          label=None,
          priority=20,
          value=Some("model-a:default"),
          color=None,
        ),
      ),
    ),
  )
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
  recorder : QuotaRecorder,
  tracker : CodexQuotaTracker,
) -> CodexQuotaStatus {
  CodexQuotaStatus(
    events=Some(recorder.publisher(owner="posoco_ext_openai")),
    tracker=Some(tracker),
  )
}

///|
test "codex quota status publishes windows and unregisters vanished ones" {
  let recorder = QuotaRecorder::QuotaRecorder()
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  let status = tk_quota_status(recorder, tracker)
  // Before any capture, a model response publishes nothing.
  @posoco.Observer::on_event(
    status,
    None,
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
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_quota_assistant(),
      usage=None,
    ),
  )
  assert_eq(recorder.events.length(), 2)
  assert_eq(
    @kit_events.status_changed_of(recorder.events[0]),
    Some(
      @kit_events.StatusOp::Register(
        segment="5h",
        label=None,
        priority=45,
        value=Some("37.5% left"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @kit_events.status_changed_of(recorder.events[1]),
    Some(
      @kit_events.StatusOp::Register(
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
    None,
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
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_quota_assistant(),
      usage=None,
    ),
  )
  assert_eq(recorder.events.length(), 4)
  assert_eq(
    @kit_events.status_changed_of(recorder.events[2]),
    Some(
      @kit_events.StatusOp::Register(
        segment="weekly",
        label=None,
        priority=45,
        value=Some("20% left"),
        color=Some("warning"),
      ),
    ),
  )
  assert_eq(
    @kit_events.status_changed_of(recorder.events[3]),
    Some(@kit_events.StatusOp::Unregister(segment="5h")),
  )
}

///|
test "codex quota status colors exhausted windows as errors" {
  let recorder = QuotaRecorder::QuotaRecorder()
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
  let status = tk_quota_status(recorder, tracker)
  @posoco.Observer::on_event(
    status,
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_quota_assistant(),
      usage=None,
    ),
  )
  assert_eq(recorder.events.length(), 1)
  assert_eq(
    @kit_events.status_changed_of(recorder.events[0]),
    Some(
      @kit_events.StatusOp::Register(
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
  let recorder = QuotaRecorder::QuotaRecorder()
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
  let status = tk_quota_status(recorder, tracker)
  @posoco.Lifecycle::on_compose(
    status,
    @tk.tk_view(
      requires=[],
      model=@tk.ScriptedModel([]) as &@posoco.ModelPort,
      ui=@posoco.NoopUiPort() as &@posoco.UiPort,
    ),
  )
  assert_eq(recorder.events.length(), 1)
  assert_eq(
    @kit_events.status_changed_of(recorder.events[0]),
    Some(
      @kit_events.StatusOp::Register(
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
fn codex_status_ops(recorder : QuotaRecorder) -> Array[@kit_events.StatusOp] {
  let ops : Array[@kit_events.StatusOp] = []
  for event in recorder.events {
    if @kit_events.publisher_id(event) == Some("posoco_ext_openai") {
      match @kit_events.status_changed_of(event) {
        Some(op) => ops.push(op)
        None => ()
      }
    }
  }
  ops
}

///|
test "codex quota status hides windows when another provider activates" {
  let recorder = QuotaRecorder::QuotaRecorder()
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
  let status = tk_quota_status(recorder, tracker)
  @posoco.Lifecycle::on_compose(
    status,
    @tk.tk_view(
      requires=[],
      model=@tk.ScriptedModel([]) as &@posoco.ModelPort,
      ui=@posoco.NoopUiPort() as &@posoco.UiPort,
    ),
  )
  assert_eq(recorder.events.length(), 2)
  // A router `ProviderStatus` (the frozen provider contract) unregisters
  // both windows; the recorder also records the announcement itself, and the
  // listener's publications land before publish returns.
  recorder.publish_provider("deepseek")
  assert_eq(recorder.events.length(), 5)
  assert_true(@kit_events.provider_status_of(recorder.events[2]) is Some(_))
  assert_eq(
    @kit_events.status_changed_of(recorder.events[3]),
    Some(@kit_events.StatusOp::Unregister(segment="5h")),
  )
  assert_eq(
    @kit_events.status_changed_of(recorder.events[4]),
    Some(@kit_events.StatusOp::Unregister(segment="weekly")),
  )
  // Unrelated protocol traffic on the shared channel is ignored.
  recorder.publish_foreign_status()
  assert_eq(recorder.events.length(), 6)
  // The suppression gate: the other provider's responses republish nothing.
  @posoco.Observer::on_event(
    status,
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_quota_assistant(),
      usage=None,
    ),
  )
  assert_eq(recorder.events.length(), 6)
}

///|
test "codex quota status re-shows windows when codex re-activates" {
  let recorder = QuotaRecorder::QuotaRecorder()
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
  let status = tk_quota_status(recorder, tracker)
  @posoco.Lifecycle::on_compose(
    status,
    @tk.tk_view(
      requires=[],
      model=@tk.ScriptedModel([]) as &@posoco.ModelPort,
      ui=@posoco.NoopUiPort() as &@posoco.UiPort,
    ),
  )
  assert_eq(recorder.events.length(), 2)
  recorder.publish_provider("deepseek")
  assert_eq(recorder.events.length(), 5)
  // Codex re-activates: the cleared last-snapshot counts as a change, so the
  // windows re-register in remaining-quota spelling (the openai event itself
  // is recorded at index 5, the queued registers follow).
  recorder.publish_provider("openai")
  assert_eq(recorder.events.length(), 8)
  assert_eq(
    @kit_events.status_changed_of(recorder.events[6]),
    Some(
      @kit_events.StatusOp::Register(
        segment="5h",
        label=None,
        priority=45,
        value=Some("37.5% left"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @kit_events.status_changed_of(recorder.events[7]),
    Some(
      @kit_events.StatusOp::Register(
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
/// capture alone must publish the windows on the channel, and `/status` must
/// report the same percentages without a model response ever arriving.
async test "startup usage probe publishes quota and /status reports it before any chat" {
  // This file owns the openai quota view through the injected tracker; a
  // build from another test file may have left a live source in the
  // process-global registry, so clear the id before composing.
  @devkit.quota_registry_unregister("openai")
  let recorder = QuotaRecorder::QuotaRecorder()
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  let status = tk_quota_status(recorder, tracker)
  let slot = @llm.ModelSlot::ModelSlot(
    id="codex-slot",
    label="Codex",
    provider_id="openai",
    model_id="gpt-5-codex",
    port=@tk.ScriptedModel([]) as &@posoco.ModelPort,
  )
  let source : &@devkit.QuotaSource = tracker
  let router = @llm.RouterModelPort(
    slots=[slot],
    events=Some(recorder.publisher(owner="posoco_ext_llm")),
    extra_quota_sources=Map::from_array([("openai", source)]),
  )
  let view = @tk.tk_view(
    requires=[],
    model=@tk.ScriptedModel([]) as &@posoco.ModelPort,
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
    @kit_events.StatusOp::Register(
      segment="5h",
      label=None,
      priority=45,
      value=Some("50.5% left"),
      color=None,
    ),
  )
  assert_eq(
    ops[1],
    @kit_events.StatusOp::Register(
      segment="weekly",
      label=None,
      priority=45,
      value=Some("20% left"),
      color=Some("warning"),
    ),
  )
  // /status surfaces the same percentages from the event cache.
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
  let recorder = QuotaRecorder::QuotaRecorder()
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  let status = tk_quota_status(recorder, tracker)
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
/// channels sharing the process tracker each receive captures, shutting the
/// older one stops only its own notifications, and the surviving channel keeps
/// feeding both the bar and `/status` — all before any chat.
async test "coexisting publishers stay independent across channels and lifetimes" {
  // Same registry hygiene as the startup regression above.
  @devkit.quota_registry_unregister("openai")
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  let recorder_a = QuotaRecorder::QuotaRecorder()
  let recorder_b = QuotaRecorder::QuotaRecorder()
  // Older lifetime on channel A, newer on channel B; both watch the same
  // tracker.
  let status_a = tk_quota_status(recorder_a, tracker)
  let status_b = tk_quota_status(recorder_b, tracker)
  let slot = @llm.ModelSlot::ModelSlot(
    id="codex-slot",
    label="Codex",
    provider_id="openai",
    model_id="gpt-5-codex",
    port=@tk.ScriptedModel([]) as &@posoco.ModelPort,
  )
  let source : &@devkit.QuotaSource = tracker
  let router_b = @llm.RouterModelPort(
    slots=[slot],
    events=Some(recorder_b.publisher(owner="posoco_ext_llm")),
    extra_quota_sources=Map::from_array([("openai", source)]),
  )
  let view = @tk.tk_view(
    requires=[],
    model=@tk.ScriptedModel([]) as &@posoco.ModelPort,
    ui=@posoco.NoopUiPort() as &@posoco.UiPort,
  )
  // Channel B's router composes: its provider announcement scopes the newer
  // publisher
  // to openai, exactly as at startup.
  @posoco.Lifecycle::on_compose(router_b, view)
  // First capture: BOTH channels must see the windows.
  tracker.capture_readings(
    expect_codex_usage(codex_usage_fixture(), fetched_at_ms=1757000000000L),
  )
  assert_eq(codex_status_ops(recorder_a).length(), 2)
  assert_eq(codex_status_ops(recorder_b).length(), 2)
  // /status on the surviving channel reports the captured percentages.
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
  // Second capture: channel A stays silent, channel B moves on.
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
    @kit_events.StatusOp::Register(
      segment="5h",
      label=None,
      priority=45,
      value=Some("20% left"),
      color=Some("warning"),
    ),
  )
  assert_eq(
    ops_b[3],
    @kit_events.StatusOp::Register(
      segment="weekly",
      label=None,
      priority=45,
      value=Some("10% left"),
      color=Some("warning"),
    ),
  )
  // /status on channel B now reports the refreshed percentages.
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
  // The newer lifetime shuts down too: no channel sees further captures.
  @posoco.Lifecycle::on_shutdown(status_b)
  tracker.capture_readings(
    expect_codex_usage(codex_usage_fixture(), fetched_at_ms=1757000002000L),
  )
  assert_eq(codex_status_ops(recorder_a).length(), 2)
  assert_eq(codex_status_ops(recorder_b).length(), 4)
}

///|
/// A stopped publisher is dead. The channel keeps its (unsubscribable)
/// registration, so late provider events must not act for it: no unregisters
/// racing a successor that shares the source, no republish when codex
/// re-activates. A late observer event cannot resurrect it either, and a
/// capture that lands after shutdown stays the successor's alone. Normal
/// compose-time publications are untouched.
async test "stopped publisher ignores late provider and observer events" {
  let recorder = QuotaRecorder::QuotaRecorder()
  let tracker = CodexQuotaTracker::CodexQuotaTracker(now_ms=fn() {
    1757000000000L
  })
  tracker.capture_readings(
    expect_codex_usage(codex_usage_fixture(), fetched_at_ms=1757000000000L),
  )
  let view = @tk.tk_view(
    requires=[],
    model=@tk.ScriptedModel([]) as &@posoco.ModelPort,
    ui=@posoco.NoopUiPort() as &@posoco.UiPort,
  )
  // First lifetime: compose publishes normally, then it stops.
  let status_a = tk_quota_status(recorder, tracker)
  @posoco.Lifecycle::on_compose(status_a, view)
  assert_eq(codex_status_ops(recorder).length(), 2)
  @posoco.Lifecycle::on_shutdown(status_a)
  // Successor on the same channel, same shared tracker and source id.
  let status_b = tk_quota_status(recorder, tracker)
  @posoco.Lifecycle::on_compose(status_b, view)
  assert_eq(codex_status_ops(recorder).length(), 4)
  // Late non-openai provider event: only the live successor hides its
  // windows; the stopped one must not fire unregisters against the shared
  // source.
  recorder.publish_provider("deepseek")
  let ops = codex_status_ops(recorder)
  assert_eq(ops.length(), 6)
  assert_eq(ops[4], @kit_events.StatusOp::Unregister(segment="5h"))
  assert_eq(ops[5], @kit_events.StatusOp::Unregister(segment="weekly"))
  // Late openai event: only the successor republishes.
  recorder.publish_provider("openai")
  let ops = codex_status_ops(recorder)
  assert_eq(ops.length(), 8)
  assert_eq(
    ops[6],
    @kit_events.StatusOp::Register(
      segment="5h",
      label=None,
      priority=45,
      value=Some("50.5% left"),
      color=None,
    ),
  )
  assert_eq(
    ops[7],
    @kit_events.StatusOp::Register(
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
    None,
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_quota_assistant(),
      usage=None,
    ),
  )
  assert_eq(codex_status_ops(recorder).length(), 10)
}
