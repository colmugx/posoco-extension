///|
/// Whitebox tests for the speed and cache metrics extension: a real bus with
/// a capture subscriber, a scripted clock, and synthetic turn events driven
/// straight into the Observer (scoped and unscoped), plus the read-only
/// `cache_doctor` command.

///|
priv struct BusCapture {
  events : Array[@devkit.BusEvent]
}

///|
fn BusCapture::BusCapture() -> BusCapture {
  { events: [], }
}

///|
impl @devkit.BusSubscriber for BusCapture with fn on_bus_event(
  self : BusCapture,
  event : @devkit.BusEvent,
) -> Unit {
  self.events.push(event)
}

///|
/// Clock returning the next scripted millisecond value on every call.
fn stepped_clock(times : Array[Int64]) -> () -> Int64 {
  let index = Ref(0)
  fn() {
    let t = times[index.val]
    index.val += 1
    t
  }
}

///|
fn tk_assistant() -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("done")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
}

///|
fn tk_usage_out(output : Int) -> @posoco.Usage {
  {
    input_tokens: Some(100),
    output_tokens: Some(output),
    total_tokens: Some(100 + output),
    cached_input_tokens: None,
    uncached_input_tokens: None,
  }
}

///|
/// Usage with no output tokens so speed metrics stay silent and only the
/// cache accounting moves.
fn tk_usage_cache(input : Int?, cached : Int?) -> @posoco.Usage {
  {
    input_tokens: input,
    output_tokens: None,
    total_tokens: None,
    cached_input_tokens: cached,
    uncached_input_tokens: None,
  }
}

///|
fn tk_scope(session : String) -> @posoco.EventScope {
  @posoco.EventScope::{
    session_id: @posoco.SessionId::{ value: session, },
    run_id: @posoco.RunId::{ value: "run_1", },
    turn_id: @posoco.TurnId::{ value: "turn_1", },
  }
}

///|
fn tk_response(usage : @posoco.Usage?) -> @posoco.TurnEvent {
  @posoco.TurnEvent::ModelResponseReceived(message=tk_assistant(), usage~)
}

///|
test "full round publishes ttft tps avg and cache with the pinned segments" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let stats = Stats(bus=Some(bus), clock=stepped_clock([1000, 1300, 2200]))
  stats.on_event(@posoco.TurnEvent::TurnStarted)
  stats.on_event(
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::TextDelta(token="Hel"),
    ),
  )
  // 24 output tokens over the 1200ms round span -> 20.0 tokens/s.
  stats.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_assistant(),
      usage=Some(tk_usage_out(24)),
    ),
  )
  assert_eq(capture.events.length(), 4)
  assert_eq(capture.events[0].source, "posoco_ext_stats")
  assert_eq(capture.events[0].topic, "status")
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="ttft",
        label=None,
        priority=50,
        value=Some("300ms"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[1]),
    Some(
      @devkit.StatusOp::Register(
        segment="tps",
        label=None,
        priority=60,
        value=Some("20.0/s"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[2]),
    Some(
      @devkit.StatusOp::Register(
        segment="avg",
        label=None,
        priority=70,
        value=Some("20.0/s"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[3]),
    Some(
      @devkit.StatusOp::Register(
        segment="cache",
        label=None,
        priority=80,
        value=Some("0/1·0.0%"),
        color=None,
      ),
    ),
  )
}

///|
test "second round re-anchors and avg becomes the per-round mean" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let stats = Stats(
    bus=Some(bus),
    clock=stepped_clock([1000, 1300, 2200, 2700, 4000]),
  )
  // Round one: ttft 300ms, 24 tokens over 1200ms -> 20.0/s, avg 20.0/s.
  stats.on_event(@posoco.TurnEvent::TurnStarted)
  stats.on_event(
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::TextDelta(token="Hel"),
    ),
  )
  stats.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_assistant(),
      usage=Some(tk_usage_out(24)),
    ),
  )
  // Round two without a fresh TurnStarted (tool loop): the re-anchor at
  // 2200 makes ttft 500ms and the span 1800ms -> 13.3/s, avg 16.7/s.
  stats.on_event(
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::ReasoningDelta(token="hmm"),
    ),
  )
  stats.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_assistant(),
      usage=Some(tk_usage_out(24)),
    ),
  )
  assert_eq(capture.events.length(), 8)
  assert_eq(
    @devkit.decode_status_op(capture.events[3]),
    Some(
      @devkit.StatusOp::Register(
        segment="cache",
        label=None,
        priority=80,
        value=Some("0/1·0.0%"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[4]),
    Some(
      @devkit.StatusOp::Register(
        segment="ttft",
        label=None,
        priority=50,
        value=Some("500ms"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[5]),
    Some(
      @devkit.StatusOp::Register(
        segment="tps",
        label=None,
        priority=60,
        value=Some("13.3/s"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[6]),
    Some(
      @devkit.StatusOp::Register(
        segment="avg",
        label=None,
        priority=70,
        value=Some("16.7/s"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[7]),
    Some(
      @devkit.StatusOp::Register(
        segment="cache",
        label=None,
        priority=80,
        value=Some("0/2·0.0%"),
        color=None,
      ),
    ),
  )
}

///|
test "turn start and chunk events never publish" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let stats = Stats(bus=Some(bus), clock=stepped_clock([1000, 1300]))
  stats.on_event(@posoco.TurnEvent::TurnStarted)
  stats.on_event(
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::TextDelta(token="Hel"),
    ),
  )
  stats.on_event(
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::ReasoningDelta(token="hmm"),
    ),
  )
  stats.on_event(
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::ToolCallDelta(
        index=0,
        id=None,
        name=None,
        arguments_delta=None,
      ),
    ),
  )
  stats.on_event(@posoco.TurnEvent::TurnCompleted)
  assert_eq(capture.events.length(), 0)
}

///|
test "missing usage publishes ttft only but the round still re-anchors" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let stats = Stats(
    bus=Some(bus),
    clock=stepped_clock([1000, 1300, 2200, 4000]),
  )
  stats.on_event(@posoco.TurnEvent::TurnStarted)
  stats.on_event(
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::TextDelta(token="Hel"),
    ),
  )
  stats.on_event(
    @posoco.TurnEvent::ModelResponseReceived(message=tk_assistant(), usage=None),
  )
  // The response without usage only published ttft; the re-anchor at 2200
  // is proven by the next round measuring its span from there (1800ms).
  stats.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_assistant(),
      usage=Some(tk_usage_out(24)),
    ),
  )
  assert_eq(capture.events.length(), 4)
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="ttft",
        label=None,
        priority=50,
        value=Some("300ms"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[1]),
    Some(
      @devkit.StatusOp::Register(
        segment="tps",
        label=None,
        priority=60,
        value=Some("13.3/s"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[2]),
    Some(
      @devkit.StatusOp::Register(
        segment="avg",
        label=None,
        priority=70,
        value=Some("13.3/s"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[3]),
    Some(
      @devkit.StatusOp::Register(
        segment="cache",
        label=None,
        priority=80,
        value=Some("0/1·0.0%"),
        color=None,
      ),
    ),
  )
}

///|
test "zero span produces no tps but the round still re-anchors" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let stats = Stats(
    bus=Some(bus),
    clock=stepped_clock([1000, 1000, 1000, 3000]),
  )
  stats.on_event(@posoco.TurnEvent::TurnStarted)
  stats.on_event(
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::TextDelta(token="Hel"),
    ),
  )
  // Response in the same millisecond as round start: the zero span
  // suppresses tps, and no tps round has accumulated yet (ttft is still
  // published — it only needs both anchors).
  stats.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_assistant(),
      usage=Some(tk_usage_out(24)),
    ),
  )
  // Re-anchor proven: the next round measures 2000ms -> 6.0 tokens/s.
  stats.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_assistant(),
      usage=Some(tk_usage_out(12)),
    ),
  )
  assert_eq(capture.events.length(), 5)
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="ttft",
        label=None,
        priority=50,
        value=Some("0ms"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[1]),
    Some(
      @devkit.StatusOp::Register(
        segment="cache",
        label=None,
        priority=80,
        value=Some("0/1·0.0%"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[2]),
    Some(
      @devkit.StatusOp::Register(
        segment="tps",
        label=None,
        priority=60,
        value=Some("6.0/s"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[3]),
    Some(
      @devkit.StatusOp::Register(
        segment="avg",
        label=None,
        priority=70,
        value=Some("6.0/s"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[4]),
    Some(
      @devkit.StatusOp::Register(
        segment="cache",
        label=None,
        priority=80,
        value=Some("0/2·0.0%"),
        color=None,
      ),
    ),
  )
}

///|
test "stats with no bus is a silent no-op that still tracks rounds" {
  let stats = Stats(clock=stepped_clock([1000, 1300, 2200, 2700, 4000]))
  stats.on_event(@posoco.TurnEvent::TurnStarted)
  stats.on_event(
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::TextDelta(token="Hel"),
    ),
  )
  stats.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_assistant(),
      usage=Some(tk_usage_out(24)),
    ),
  )
  stats.on_event(
    @posoco.TurnEvent::StreamChunkReceived(
      chunk=@posoco.StreamChunk::TextDelta(token="lo"),
    ),
  )
  stats.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=tk_assistant(),
      usage=Some(tk_usage_out(24)),
    ),
  )
  assert_eq(stats.tps_rounds, 2)
  assert_eq(stats.round_started_ms, Some(4000L))
  assert_true(stats.first_token_ms is None)
  // Unscoped dispatch falls back to the "(no scope)" process bucket.
  match stats.cache_buckets.get("(no scope)") {
    Some(bucket) => {
      assert_eq(bucket.requests, 2)
      assert_eq(bucket.hit_requests, 0)
      assert_eq(bucket.sum_input, 200)
      assert_eq(bucket.sum_cached, 0)
    }
    None => fail("expected the no-scope bucket")
  }
}

///|
test "cache buckets split by session scope and the segment aggregates them" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let stats = Stats(
    bus=Some(bus),
    clock=stepped_clock([1000, 1100, 1200, 1300]),
  )
  let scope_a = tk_scope("session_a")
  let scope_b = tk_scope("session_b")
  stats.on_event_at(
    Some(scope_a),
    tk_response(Some(tk_usage_cache(Some(100), Some(50)))),
  )
  stats.on_event_at(
    Some(scope_a),
    tk_response(Some(tk_usage_cache(Some(100), None))),
  )
  // A reported zero is not a hit.
  stats.on_event_at(
    Some(scope_b),
    tk_response(Some(tk_usage_cache(Some(200), Some(0)))),
  )
  stats.on_event_at(None, tk_response(Some(tk_usage_cache(Some(50), Some(40)))))
  assert_eq(capture.events.length(), 4)
  let expected = [
    "1/1·50.0%", "1/2·25.0%", "1/3·12.5%",
    // Aggregate over both sessions plus the no-scope bucket: 90/450.
     "2/4·20.0%",
  ]
  for i, value in expected {
    assert_eq(
      @devkit.decode_status_op(capture.events[i]),
      Some(
        @devkit.StatusOp::Register(
          segment="cache",
          label=None,
          priority=80,
          value=Some(value),
          color=None,
        ),
      ),
    )
  }
  match stats.cache_buckets.get("session_a") {
    Some(bucket) => {
      assert_eq(bucket.requests, 2)
      assert_eq(bucket.hit_requests, 1)
      assert_eq(bucket.sum_input, 200)
      assert_eq(bucket.sum_cached, 50)
    }
    None => fail("expected a session_a bucket")
  }
  match stats.cache_buckets.get("session_b") {
    Some(bucket) => {
      assert_eq(bucket.requests, 1)
      assert_eq(bucket.hit_requests, 0)
      assert_eq(bucket.sum_cached, 0)
    }
    None => fail("expected a session_b bucket")
  }
  assert_true(stats.cache_buckets.contains("(no scope)"))
}

///|
test "cache accounting never coerces absent fields to zero" {
  let stats = Stats(clock=fn() { 0L })
  // Usage present but empty: the round counts, nothing else moves.
  stats.on_event_at(
    Some(tk_scope("s")),
    tk_response(Some(tk_usage_cache(None, None))),
  )
  // Zero cached tokens is reported but is not a hit.
  stats.on_event_at(
    Some(tk_scope("s")),
    tk_response(Some(tk_usage_cache(Some(100), Some(0)))),
  )
  // No usage at all: not a request.
  stats.on_event_at(Some(tk_scope("s")), tk_response(None))
  match stats.cache_buckets.get("s") {
    Some(bucket) => {
      assert_eq(bucket.requests, 2)
      assert_eq(bucket.hit_requests, 0)
      assert_eq(bucket.sum_input, 100)
      assert_eq(bucket.sum_cached, 0)
    }
    None => fail("expected an s bucket")
  }
}

///|
test "cache segment is withheld until input tokens are reported" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let stats = Stats(bus=Some(bus), clock=stepped_clock([1000, 2000, 3000]))
  stats.on_event(tk_response(Some(tk_usage_cache(None, None))))
  stats.on_event(tk_response(None))
  assert_eq(capture.events.length(), 0)
  stats.on_event(tk_response(Some(tk_usage_cache(Some(100), Some(10)))))
  // The first publish already folds in the earlier usage-only round.
  assert_eq(capture.events.length(), 1)
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="cache",
        label=None,
        priority=80,
        value=Some("1/2·10.0%"),
        color=None,
      ),
    ),
  )
}

///|
test "manifest contributes the stats observer and the cache doctor command" {
  let stats = Stats()
  assert_eq(stats.extension_id(), "posoco_ext_stats")
  let manifest = stats.manifest()
  assert_eq(manifest.id, "posoco_ext_stats")
  assert_eq(manifest.observers.length(), 1)
  assert_eq(manifest.models.length(), 0)
  assert_eq(manifest.tools.length(), 0)
  assert_eq(manifest.sessions.length(), 0)
  assert_eq(manifest.hooks.length(), 0)
  assert_eq(manifest.memory.length(), 0)
  assert_eq(manifest.lifecycle.length(), 0)
  assert_eq(manifest.commands.length(), 1)
  assert_eq(manifest.ui.length(), 0)
  assert_eq(manifest.prompt_contributors.length(), 0)
  assert_eq(manifest.requires.length(), 0)
  let defs = stats.commands()
  assert_eq(defs.length(), 2)
  assert_eq(defs[0].id, "cache_doctor")
  assert_eq(defs[0].label, "Cache doctor")
  assert_eq(defs[0].category, "stats")
  assert_eq(defs[0].ctype, @posoco.CommandType::Action)
  assert_eq(defs[0].params.length(), 0)
  assert_true(defs[0].visible)
  assert_eq(defs[1].id, "usage")
  assert_eq(defs[1].label, "Token usage")
  assert_eq(defs[1].category, "stats")
  assert_eq(defs[1].ctype, @posoco.CommandType::Action)
  assert_eq(defs[1].params.length(), 0)
  assert_true(defs[1].visible)
}

///|
async test "cache_doctor reports bucket aggregate and structured summary" {
  let stats = Stats()
  stats.on_event_at(
    Some(tk_scope("s1")),
    tk_response(Some(tk_usage_cache(Some(840000), Some(660000)))),
  )
  match stats.invoke("cache_doctor", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ui_hint~) => {
      assert_eq(
        feedback, "session s1: 1/1 requests·660.0K/840.0K tok·78.6%\naggregate: 1/1 requests·660.0K/840.0K tok·78.6%",
      )
      assert_eq(ui_hint, Some(@posoco.UiHint::None))
      match structured {
        Some(Json::Object(fields)) => {
          match fields.get("kind") {
            Some(Json::String("stats_cache_doctor")) => ()
            _ => fail("expected kind stats_cache_doctor")
          }
          match fields.get("sessions") {
            Some(Json::Array(entries)) => {
              assert_eq(entries.length(), 1)
              match entries[0] {
                Json::Object(bucket) => {
                  match bucket.get("session") {
                    Some(Json::String("s1")) => ()
                    _ => fail("expected session s1 entry")
                  }
                  match bucket.get("sum_cached_tokens") {
                    Some(Json::Number(n, ..)) => assert_eq(n, 660000.0)
                    _ => fail("expected sum_cached_tokens number")
                  }
                }
                _ => fail("expected a bucket object")
              }
            }
            _ => fail("expected sessions array")
          }
          match fields.get("diagnosis") {
            Some(_) => fail("no diagnosis expected below the threshold")
            None => ()
          }
        }
        _ => fail("expected structured object")
      }
    }
    _ => fail("expected success outcome")
  }
}

///|
async test "cache_doctor sorts sessions and sums the aggregate" {
  let stats = Stats()
  stats.on_event_at(
    Some(tk_scope("s2")),
    tk_response(Some(tk_usage_cache(Some(1000), Some(100)))),
  )
  stats.on_event_at(
    Some(tk_scope("s1")),
    tk_response(Some(tk_usage_cache(Some(1000), Some(300)))),
  )
  match stats.invoke("cache_doctor", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      // Insertion order is s2 then s1; the report must come out sorted, and
      // the aggregate line must fold both sessions together.
      assert_eq(
        feedback, "session s1: 1/1 requests·300/1.0K tok·30.0%\nsession s2: 1/1 requests·100/1.0K tok·10.0%\naggregate: 2/2 requests·400/2.0K tok·20.0%",
      )
    _ => fail("expected success outcome")
  }
}

///|
async test "cache_doctor warns only after five requests with a near-zero hit rate" {
  let stats = Stats()
  for _i in 0..<4 {
    stats.on_event_at(
      Some(tk_scope("s")),
      tk_response(Some(tk_usage_cache(Some(100), Some(0)))),
    )
  }
  match stats.invoke("cache_doctor", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_false(feedback.contains("warning"))
      match structured {
        Some(Json::Object(fields)) =>
          match fields.get("diagnosis") {
            Some(_) => fail("no diagnosis expected below the threshold")
            None => ()
          }
        _ => fail("expected structured object")
      }
    }
    _ => fail("expected success outcome")
  }
  stats.on_event_at(
    Some(tk_scope("s")),
    tk_response(Some(tk_usage_cache(Some(100), Some(0)))),
  )
  match stats.invoke("cache_doctor", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("warning"))
      assert_true(feedback.contains("session affinity"))
      match structured {
        Some(Json::Object(fields)) =>
          match fields.get("diagnosis") {
            Some(Json::String(_)) => ()
            _ => fail("expected diagnosis string in structured payload")
          }
        _ => fail("expected structured object")
      }
    }
    _ => fail("expected success outcome")
  }
}

///|
async test "cache_doctor unknown id raises NotFound" {
  let stats = Stats()
  try stats.invoke("nope", Json::null()) catch {
    @posoco.CommandError::NotFound(id) => assert_eq(id, "nope")
    other => fail("expected NotFound, got: \{other}")
  } noraise {
    _ => fail("expected NotFound to raise")
  }
}

///|
fn tk_usage_full(input : Int?, cached : Int?, output : Int?) -> @posoco.Usage {
  {
    input_tokens: input,
    output_tokens: output,
    total_tokens: None,
    cached_input_tokens: cached,
    uncached_input_tokens: None,
  }
}

///|
async test "usage reports cumulative labeled accounting per session and aggregate" {
  let stats = Stats()
  stats.on_event_at(
    Some(tk_scope("s1")),
    tk_response(Some(tk_usage_full(Some(1000), Some(100), Some(24)))),
  )
  stats.on_event_at(
    Some(tk_scope("s1")),
    tk_response(Some(tk_usage_full(Some(500), None, Some(12)))),
  )
  stats.on_event_at(
    Some(tk_scope("s2")),
    tk_response(Some(tk_usage_full(Some(2000), Some(0), Some(10)))),
  )
  // Usage with every field absent still counts its request, contributing
  // nothing to the sums; a response without usage counts nothing at all.
  stats.on_event_at(
    Some(tk_scope("s3")),
    tk_response(Some(tk_usage_full(None, None, None))),
  )
  stats.on_event_at(Some(tk_scope("s1")), tk_response(None))
  match stats.invoke("usage", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_eq(
        feedback, "session s1: 2 requests · in 1.5K · out 36 · cache hits 1/2 (6.7%)\nsession s2: 1 requests · in 2.0K · out 10 · cache hits 0/1 (0.0%)\nsession s3: 1 requests · in 0 · out 0 · cache hits 0/1\naggregate: 4 requests · in 3.5K · out 46 · cache hits 1/4 (2.9%)",
      )
      match structured {
        Some(Json::Object(fields)) => {
          match fields.get("kind") {
            Some(Json::String("stats_usage")) => ()
            _ => fail("expected kind stats_usage")
          }
          match fields.get("aggregate") {
            Some(Json::Object(aggregate)) =>
              match aggregate.get("sum_output_tokens") {
                Some(Json::Number(n, ..)) => assert_eq(n, 46.0)
                _ => fail("expected sum_output_tokens number")
              }
            _ => fail("expected aggregate object")
          }
        }
        _ => fail("expected structured object")
      }
    }
    _ => fail("expected success outcome")
  }
}

///|
async test "usage on a fresh stats renders an empty aggregate without a rate" {
  let stats = Stats()
  match stats.invoke("usage", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_eq(
        feedback, "aggregate: 0 requests · in 0 · out 0 · cache hits 0/0",
      )
    _ => fail("expected success outcome")
  }
}
