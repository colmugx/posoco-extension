///|
const FOOTER = "child_session: cs_1\nusage: turns=3 in=100 out=50"

///|
test "terminal_completed_maps_to_success" {
  let outcome = terminal_outcome(
    state=Completed,
    kind="coder",
    child_session="cs_1",
    result_text="done: fixed the bug",
    turns=3,
    input_tokens=100,
    output_tokens=50,
  )
  let (content, structured) = match outcome {
    @posoco.ToolOutcome::Success(content~, structured~) => (content, structured)
    _ => fail("expected Success")
  }
  assert_eq(content, "done: fixed the bug\n" + FOOTER)
  let payload = match structured {
    Some(payload) => payload
    None => fail("expected structured payload")
  }
  match payload {
    Object(fields) => {
      assert_eq(fields.get("state"), Some(Json::string("completed")))
      assert_eq(fields.get("child_session"), Some(Json::string("cs_1")))
      assert_eq(fields.get("turns"), Some(Json::number(3.0)))
      assert_eq(fields.get("input_tokens"), Some(Json::number(100.0)))
      assert_eq(fields.get("output_tokens"), Some(Json::number(50.0)))
      assert_eq(fields.get("kind"), Some(Json::string("coder")))
      assert_eq(fields.get("reason"), None)
    }
    _ => fail("expected structured object")
  }
}

///|
test "terminal_failed_maps_to_tool_reported_error_with_reason" {
  let outcome = terminal_outcome(
    state=Failed(reason="tests failed: expected 4, got 5"),
    kind="reviewer",
    child_session="cs_1",
    result_text="partial output",
    turns=3,
    input_tokens=100,
    output_tokens=50,
  )
  assert_true(outcome is @posoco.ToolOutcome::ToolReportedError(..))
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, structured~) => {
      assert_eq(content, "failed: tests failed: expected 4, got 5\n" + FOOTER)
      match structured {
        Some(Object(fields)) => {
          assert_eq(fields.get("state"), Some(Json::string("failed")))
          assert_eq(
            fields.get("reason"),
            Some(Json::string("tests failed: expected 4, got 5")),
          )
          assert_eq(fields.get("child_session"), Some(Json::string("cs_1")))
        }
        _ => fail("expected structured object")
      }
    }
    _ => fail("unreachable")
  }
}

///|
test "terminal_timed_out_maps_to_tool_reported_error" {
  let outcome = terminal_outcome(
    state=TimedOut,
    kind="scout",
    child_session="cs_1",
    result_text="",
    turns=3,
    input_tokens=100,
    output_tokens=50,
  )
  assert_true(outcome is @posoco.ToolOutcome::ToolReportedError(..))
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, structured~) => {
      assert_eq(content, "timed out\n" + FOOTER)
      match structured {
        Some(Object(fields)) => {
          assert_eq(fields.get("state"), Some(Json::string("timed_out")))
          assert_eq(fields.get("reason"), None)
        }
        _ => fail("expected structured object")
      }
    }
    _ => fail("unreachable")
  }
}

///|
test "terminal_cancelled_maps_to_tool_reported_error" {
  let outcome = terminal_outcome(
    state=Cancelled,
    kind="oracle",
    child_session="cs_1",
    result_text="half a report",
    turns=3,
    input_tokens=100,
    output_tokens=50,
  )
  assert_true(outcome is @posoco.ToolOutcome::ToolReportedError(..))
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, structured~) => {
      assert_eq(content, "cancelled\n" + FOOTER)
      match structured {
        Some(Object(fields)) =>
          assert_eq(fields.get("state"), Some(Json::string("cancelled")))
        _ => fail("expected structured object")
      }
    }
    _ => fail("unreachable")
  }
}

///|
test "subagent_event_carries_child_identity" {
  let event : SubagentEvent = {
    child_session: "cs_9",
    kind: "scout",
    event: @posoco.TurnEvent::TurnStarted,
  }
  assert_eq(event.child_session, "cs_9")
  assert_eq(event.kind, "scout")
  assert_true(event.event is @posoco.TurnEvent::TurnStarted)
}
