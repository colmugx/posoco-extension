///|
test "stale prepared checkpoint never rewrites canonical history" {
  let original = @posoco.tk_user_msg("original")
  let changed = @posoco.tk_user_msg("changed")
  let latest = @posoco.tk_user_msg("latest")
  let candidate : RuntimeCandidate = {
    id: "cc_stale",
    session_id: "s1",
    run_id: "r1",
    start_index: 0,
    end_index: 1,
    estimated_tokens: 10,
    source_messages: [original],
  }
  let prepared : PreparedCheckpoint = {
    checkpoint_id: "cp_stale",
    candidate,
    summary: {
      goal: "old work",
      completed: ["done"],
      decisions: [],
      artifacts: [],
      facts: [],
      open_threads: [],
    },
  }
  assert_eq(apply_prepared_checkpoint([changed, latest], prepared), None)
}

fn runtime_test_call(name : String, arguments : Json) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("runtime_test_" + name),
    name: @posoco.ToolName::unchecked(name),
    arguments,
  }
}

///|
async test "history tools stay scoped to the active session" {
  let model = @posoco.ScriptedModel([])
  let continuity = continuity_extension(model as &@posoco.ModelPort)
  continuity.turn_active = true
  continuity.active_session_id = Some("s1")
  continuity.active_run_id = Some("r1")
  continuity.archive.append(
    "s1",
    [
      {
        id: "hist_s1",
        checkpoint_id: "cp_1",
        ordinal: 0,
        message: @posoco.tk_user_msg("SESSION_ONE_EXACT_MARKER"),
      },
    ],
  )
  continuity.archive.append(
    "s2",
    [
      {
        id: "hist_s2",
        checkpoint_id: "cp_2",
        ordinal: 0,
        message: @posoco.tk_user_msg("SESSION_TWO_SECRET_MARKER"),
      },
    ],
  )

  let tools = continuity as &@posoco.ToolProvider
  let search = tools.execute(
    "session_history_search",
    runtime_test_call(
      "session_history_search",
      Json::object(
        Map::from_array([
          ("query", Json::string("SESSION_ONE_EXACT_MARKER")),
        ]),
      ),
    ),
  )
  match search {
    @posoco.ToolOutcome::Success(content~, ..) => {
      assert_true(content.contains("hist_s1"))
      assert_false(content.contains("hist_s2"))
    }
    _ => fail("expected session_history_search success")
  }

  let cross_session_search = tools.execute(
    "session_history_search",
    runtime_test_call(
      "session_history_search",
      Json::object(
        Map::from_array([
          ("query", Json::string("SESSION_TWO_SECRET_MARKER")),
        ]),
      ),
    ),
  )
  match cross_session_search {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("no archived history matched"))
    _ => fail("expected bounded empty search result")
  }

  let read = tools.execute(
    "session_history_read",
    runtime_test_call(
      "session_history_read",
      Json::object(
        Map::from_array([
          ("ref", Json::string("hist_s1")),
          ("cursor", Json::string("0")),
        ]),
      ),
    ),
  )
  match read {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("SESSION_ONE_EXACT_MARKER"))
    _ => fail("expected session_history_read success")
  }

  let status = tools.execute(
    "session_continuity_status",
    runtime_test_call(
      "session_continuity_status",
      Json::object(Map::from_array([])),
    ),
  )
  match status {
    @posoco.ToolOutcome::Success(content~, ..) => {
      assert_true(content.contains("s1"))
      assert_true(content.contains("archived_messages"))
    }
    _ => fail("expected session_continuity_status success")
  }
}
