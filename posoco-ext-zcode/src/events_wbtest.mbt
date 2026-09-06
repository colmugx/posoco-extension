///|
/// Payload fragments are real values from
/// docs/fixtures/zcode-appserver-transcript.jsonl unless marked mocked.
/// The fixture generator stripped the session/event envelope, so params are
/// given the documented `type` discriminator directly. Multiline strings are
/// always let-bound first: passing them directly as arguments is deprecated.

///|
fn events_params(text : String) -> Json raise {
  @json.parse(text) catch {
    err => fail(err.to_string())
  }
}

///|
test "reduce_ignores_noise_methods" {
  let params = events_params(
    (
      #|{"type": "turn.started", "patch": {"status": "running"}}
    ),
  )
  for
    method_name in [
      "state.updated", "v4/telemetry/event", "process/mcpTelemetry", "computer-use/operation-event",
    ] {
    assert_true(zcode_reduce_notification(method_name, params) is None)
  }
}

///|
test "reduce_turn_started" {
  let params = events_params(
    (
      #|{"type": "turn.started"}
    ),
  )
  assert_true(
    zcode_reduce_notification("session/event", params) is Some(TurnStarted),
  )
}

///|
test "reduce_text_delta_from_real_streaming_payload" {
  let params = events_params(
    (
      #|{"type": "model.streaming", "delta": "pong", "done": false, "kind": "text_delta"}
    ),
  )
  match zcode_reduce_notification("session/event", params) {
    Some(TextDelta(delta)) => assert_eq(delta, "pong")
    _ => fail("expected TextDelta")
  }
}

///|
test "reduce_reasoning_delta" {
  let params = events_params(
    (
      #|{"type": "model.streaming", "delta": "checking the path", "done": false, "kind": "reasoning_delta"}
    ),
  )
  match zcode_reduce_notification("session/event", params) {
    Some(ReasoningDelta(delta)) => assert_eq(delta, "checking the path")
    _ => fail("expected ReasoningDelta")
  }
}

///|
test "reduce_model_streaming_unknown_kind_or_missing_delta_none" {
  let tool_delta = events_params(
    (
      #|{"type": "model.streaming", "kind": "tool_delta", "delta": "x"}
    ),
  )
  assert_true(zcode_reduce_notification("session/event", tool_delta) is None)
  let missing_delta = events_params(
    (
      #|{"type": "model.streaming", "kind": "text_delta"}
    ),
  )
  assert_true(zcode_reduce_notification("session/event", missing_delta) is None)
}

///|
test "reduce_tool_updated" {
  let params = events_params(
    (
      #|{"type": "tool.updated", "toolName": "bash", "kind": "started"}
    ),
  )
  match zcode_reduce_notification("session/event", params) {
    Some(ToolUpdated(tool_name~, status~)) => {
      assert_eq(tool_name, "bash")
      assert_eq(status, "started")
    }
    _ => fail("expected ToolUpdated")
  }
}

///|
test "reduce_usage_sample_from_session_updated" {
  let params = events_params(
    (
      #|{"type": "session.updated", "usage": {"inputTokens": 28853, "outputTokens": 3, "totalTokens": 28856, "cacheReadTokens": 10368}}
    ),
  )
  match zcode_reduce_notification("session/event", params) {
    Some(UsageSample(usage)) => {
      assert_eq(usage.input_tokens, 28853)
      assert_eq(usage.output_tokens, 3)
      assert_eq(usage.total_tokens, 28856)
    }
    _ => fail("expected UsageSample")
  }
}

///|
test "reduce_session_updated_without_usage_none" {
  let params = events_params(
    (
      #|{"type": "session.updated"}
    ),
  )
  assert_true(zcode_reduce_notification("session/event", params) is None)
}

///|
test "reduce_title_updated" {
  let params = events_params(
    (
      #|{"type": "session.titleUpdated", "title": "Request for single word pong reply"}
    ),
  )
  match zcode_reduce_notification("session/event", params) {
    Some(TitleUpdated(title)) =>
      assert_eq(title, "Request for single word pong reply")
    _ => fail("expected TitleUpdated")
  }
}

///|
test "reduce_turn_completed_with_response_and_usage" {
  let params = events_params(
    (
      #|{"type": "turn.completed", "response": "pong", "tokenCount": 28856, "usage": {"source": "provider", "inputTokens": 28853, "outputTokens": 3, "totalTokens": 28856}, "resultType": "success"}
    ),
  )
  match zcode_reduce_notification("session/event", params) {
    Some(TurnCompleted(response~, usage~)) => {
      assert_eq(response, "pong")
      match usage {
        Some(u) => assert_eq(u.total_tokens, 28856)
        None => fail("expected usage")
      }
    }
    _ => fail("expected TurnCompleted")
  }
}

///|
test "reduce_turn_completed_tolerates_missing_response_and_usage" {
  let params = events_params(
    (
      #|{"type": "turn.completed"}
    ),
  )
  match zcode_reduce_notification("session/event", params) {
    Some(TurnCompleted(response~, usage~)) => {
      assert_eq(response, "")
      assert_true(usage is None)
    }
    _ => fail("expected TurnCompleted")
  }
}

///|
test "reduce_turn_failed_message" {
  let params = events_params(
    (
      #|{"type": "turn.failed", "error": {"message": "Model config is missing for provider builtin:bigmodel-coding-plan"}}
    ),
  )
  match zcode_reduce_notification("session/event", params) {
    Some(TurnFailed(message~)) => assert_true(message.contains("Model config"))
    _ => fail("expected TurnFailed")
  }
}

///|
test "reduce_unknown_event_type_none" {
  let params = events_params(
    (
      #|{"type": "slashCommands.updated", "commands": []}
    ),
  )
  assert_true(zcode_reduce_notification("session/event", params) is None)
}
