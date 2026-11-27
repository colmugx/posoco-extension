///|
fn tk_named_tool_call(id : String, name : String) -> @posoco.ToolCall {
  @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked(id),
    name: @posoco.ToolName::unchecked(name),
    arguments: Json::object(Map::from_array([])),
  }
}

///|
async test "perf tracks turn duration, model latency, parallel tool breakdown, and cache savings" {
  // Scripted clock:
  // 1000: TurnStarted
  // 1050: ModelRequestStarted (round 1)
  // 1250: first delta (ttft = 200ms)
  // 1450: ModelResponseReceived (round 1 model_ms = 400ms)
  // 1460: ToolCallStarted read c1
  // 1470: ToolCallStarted grep c2 (parallel)
  // 1510: ToolCallSucceeded read c1 (50ms)
  // 1670: ToolCallSucceeded grep c2 (200ms)
  // 1680: ModelRequestStarted (round 2)
  // 1780: first delta (ttft = 100ms)
  // 1980: ModelResponseReceived (round 2 model_ms = 300ms, no usage)
  // 2000: TurnCompleted (turn_ms = 1000ms)
  let stats = Stats(
    clock=stepped_clock([
      1000, 1050, 1250, 1450, 1460, 1470, 1510, 1670, 1680, 1780, 1980, 2000,
    ]),
    live_interval_ms=suppress_live,
  )
  let s1 = Some(tk_scope("s1"))
  let c1 = tk_named_tool_call("c1", "read")
  let c2 = tk_named_tool_call("c2", "grep")
  stats.on_event(s1, @posoco.TurnEvent::TurnStarted)
  stats.on_event(s1, @posoco.TurnEvent::ModelRequestStarted)
  stats.on_event(s1, tk_delta("hi"))
  stats.on_event(
    s1,
    tk_response(Some(tk_usage_full(Some(1000), Some(750), Some(20)))),
  )
  stats.on_event(s1, @posoco.TurnEvent::ToolCallStarted(call=c1))
  stats.on_event(s1, @posoco.TurnEvent::ToolCallStarted(call=c2))
  stats.on_event(
    s1,
    @posoco.TurnEvent::ToolCallSucceeded(
      call=c1,
      content="ok",
      structured=None,
      attachments=[],
    ),
  )
  stats.on_event(
    s1,
    @posoco.TurnEvent::ToolCallSucceeded(
      call=c2,
      content="ok",
      structured=None,
      attachments=[],
    ),
  )
  stats.on_event(s1, @posoco.TurnEvent::ModelRequestStarted)
  stats.on_event(s1, tk_delta("done"))
  stats.on_event(s1, tk_response(None))
  stats.on_event(s1, @posoco.TurnEvent::TurnCompleted)
  match stats.invoke("perf", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ui_hint~) => {
      assert_eq(ui_hint, Some(@posoco.UiHint::None))
      assert_true(
        feedback.contains(
          "session s1: 1 turns (1.0s) · 2 model (700ms, avg ttft 150ms) · 2 tools (250ms) · cache 1/1 (75.0%, 750 saved)",
        ),
      )
      assert_true(
        feedback.contains(
          "aggregate: 1 turns (1.0s) · 2 model (700ms, avg ttft 150ms) · 2 tools (250ms) · cache 1/1 (75.0%, 750 saved)",
        ),
      )
      // Tool summary sorts slowest total time first: grep (200ms) before read (50ms).
      assert_true(
        feedback.contains(
          "tools: grep 1 (200ms, max 200ms) · read 1 (50ms, max 50ms)",
        ),
      )
      match structured {
        Some(Json::Object(fields)) => {
          assert_true(fields.get("kind") is Some(Json::String("stats_perf")))
          match fields.get("aggregate") {
            Some(Json::Object(agg)) => {
              assert_true(agg.get("turns") is Some(Json::Number(1.0, ..)))
              assert_true(
                agg.get("completed_turns") is Some(Json::Number(1.0, ..)),
              )
              assert_true(
                agg.get("sum_turn_ms") is Some(Json::Number(1000.0, ..)),
              )
              assert_true(
                agg.get("model_requests") is Some(Json::Number(2.0, ..)),
              )
              assert_true(
                agg.get("sum_model_ms") is Some(Json::Number(700.0, ..)),
              )
              assert_true(agg.get("ttft_rounds") is Some(Json::Number(2.0, ..)))
              assert_true(
                agg.get("sum_ttft_ms") is Some(Json::Number(300.0, ..)),
              )
              assert_true(agg.get("tool_calls") is Some(Json::Number(2.0, ..)))
              assert_true(
                agg.get("sum_tool_ms") is Some(Json::Number(250.0, ..)),
              )
            }
            _ => fail("expected aggregate timing object")
          }
          match fields.get("cache") {
            Some(Json::Object(cache)) => {
              assert_true(
                cache.get("sum_cached_tokens") is Some(Json::Number(750.0, ..)),
              )
              assert_true(
                cache.get("sum_uncached_cache_input_tokens")
                is Some(Json::Number(250.0, ..)),
              )
            }
            _ => fail("expected cache summary object")
          }
        }
        _ => fail("expected structured stats_perf object")
      }
    }
    _ => fail("expected perf command success")
  }
}

///|
async test "perf records failed, abandoned, and rejected tools and cleans up orphaned calls on cancel" {
  // 1000: TurnStarted (s1)
  // 1050: ToolCallStarted bash b1
  // 1200: ToolCallFailed bash b1 (150ms)
  // 1210: ToolCallStarted edit e1 (orphaned when turn cancels)
  // 1300: TurnCancelled (turn_ms = 300ms)
  // 2000: TurnStarted (s1, second turn)
  // 2050: ToolCallStarted edit e1 (reused call_id must measure cleanly)
  // 2080: ToolCallAbandoned edit e1 (30ms)
  // 2100: TurnFailed (turn_ms = 100ms)
  let stats = Stats(
    clock=stepped_clock([1000, 1050, 1200, 1210, 1300, 2000, 2050, 2080, 2100]),
    live_interval_ms=suppress_live,
  )
  let s1 = Some(tk_scope("s1"))
  let b1 = tk_named_tool_call("b1", "bash")
  let e1 = tk_named_tool_call("e1", "edit")
  let r1 = tk_named_tool_call("r1", "write")
  stats.on_event(s1, @posoco.TurnEvent::TurnStarted)
  stats.on_event(s1, @posoco.TurnEvent::ToolCallStarted(call=b1))
  stats.on_event(
    s1,
    @posoco.TurnEvent::ToolCallFailed(
      call=b1,
      failure=ReportedError(content="exit 1", structured=None),
    ),
  )
  stats.on_event(
    s1,
    @posoco.TurnEvent::ToolCallRejected(
      call=r1,
      reason=@posoco.NotExecutedReason::RejectedByHook(reason="policy"),
    ),
  )
  stats.on_event(s1, @posoco.TurnEvent::ToolCallStarted(call=e1))
  stats.on_event(s1, @posoco.TurnEvent::TurnCancelled)
  stats.on_event(s1, @posoco.TurnEvent::TurnStarted)
  stats.on_event(s1, @posoco.TurnEvent::ToolCallStarted(call=e1))
  stats.on_event(
    s1,
    @posoco.TurnEvent::ToolCallAbandoned(call=e1, reason="aborted"),
  )
  stats.on_event(s1, @posoco.TurnEvent::TurnFailed("boom"))
  match stats.invoke("perf", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("2 turns (400ms)"))
      assert_true(feedback.contains("2 tools (180ms, 2 err/1 rej)"))
      assert_true(feedback.contains("bash 1 (150ms, max 150ms, 1 failed)"))
      assert_true(feedback.contains("edit 1 (30ms, max 30ms, 1 abandoned)"))
      assert_true(feedback.contains("write 0 (0ms, max 0ms, 1 rejected)"))
      match structured {
        Some(Json::Object(fields)) =>
          match fields.get("aggregate") {
            Some(Json::Object(agg)) => {
              assert_true(
                agg.get("cancelled_turns") is Some(Json::Number(1.0, ..)),
              )
              assert_true(
                agg.get("failed_turns") is Some(Json::Number(1.0, ..)),
              )
              assert_true(
                agg.get("tool_failures") is Some(Json::Number(2.0, ..)),
              )
              assert_true(
                agg.get("tool_rejected") is Some(Json::Number(1.0, ..)),
              )
              assert_true(
                agg.get("sum_tool_ms") is Some(Json::Number(180.0, ..)),
              )
            }
            _ => fail("expected aggregate object")
          }
        _ => fail("expected structured object")
      }
    }
    _ => fail("expected perf success")
  }
}

///|
async test "perf on fresh stats renders zeroed aggregate without tool breakdown" {
  let stats = Stats()
  match stats.invoke("perf", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      assert_eq(
        feedback, "aggregate: 0 turns (0ms) · 0 model (0ms) · 0 tools (0ms) · cache n/a",
      )
      assert_false(feedback.contains("tools:"))
    }
    _ => fail("expected perf success")
  }
}

///|
async test "perf separates multiple sessions and aggregates shared tool names" {
  // s2: TurnStarted(100), ToolCallStarted read(120), ToolCallSucceeded read(150 -> 30ms), TurnCompleted(200 -> 100ms)
  // s1: TurnStarted(300), ToolCallStarted read(310), ToolCallSucceeded read(400 -> 90ms), TurnCompleted(500 -> 200ms)
  let stats = Stats(
    clock=stepped_clock([100, 120, 150, 200, 300, 310, 400, 500]),
    live_interval_ms=suppress_live,
  )
  let s1 = Some(tk_scope("s1"))
  let s2 = Some(tk_scope("s2"))
  let r_a = tk_named_tool_call("a", "read")
  let r_b = tk_named_tool_call("b", "read")
  stats.on_event(s2, @posoco.TurnEvent::TurnStarted)
  stats.on_event(s2, @posoco.TurnEvent::ToolCallStarted(call=r_a))
  stats.on_event(
    s2,
    @posoco.TurnEvent::ToolCallSucceeded(
      call=r_a,
      content="ok",
      structured=None,
      attachments=[],
    ),
  )
  stats.on_event(s2, @posoco.TurnEvent::TurnCompleted)
  stats.on_event(s1, @posoco.TurnEvent::TurnStarted)
  stats.on_event(s1, @posoco.TurnEvent::ToolCallStarted(call=r_b))
  stats.on_event(
    s1,
    @posoco.TurnEvent::ToolCallSucceeded(
      call=r_b,
      content="ok",
      structured=None,
      attachments=[],
    ),
  )
  stats.on_event(s1, @posoco.TurnEvent::TurnCompleted)
  match stats.invoke("perf", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      let lines = feedback.split("\n").to_array()
      assert_eq(lines.length(), 4)
      assert_true(lines[0].has_prefix("session s1: 1 turns (200ms)"))
      assert_true(lines[1].has_prefix("session s2: 1 turns (100ms)"))
      assert_true(lines[2].has_prefix("aggregate: 2 turns (300ms)"))
      assert_eq(lines[3], "tools: read 2 (120ms, max 90ms)")
    }
    _ => fail("expected perf success")
  }
}
