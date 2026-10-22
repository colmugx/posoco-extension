///|
async test "list_tools_contains_bash" {
  let tools = ShellTools()
  let tool_defs = tools.list_tools()
  let names = tool_defs.map(fn(t) { t.name.to_string() })
  assert_true(names.contains("bash"))
  assert_eq(tool_defs.length(), 4)
}

///|
async test "list_tools_tool_defs_have_descriptions" {
  let tools = ShellTools()
  let tool_defs = tools.list_tools()
  for tool in tool_defs {
    assert_true(tool.description.length() > 0)
  }
}

///|
async test "list_tools_tool_defs_have_input_schema" {
  let tools = ShellTools()
  let tool_defs = tools.list_tools()
  for tool in tool_defs {
    assert_true(tool.input_schema is Json::Object(_))
  }
}

///|
async test "list_tools_have_provenance" {
  let tools = ShellTools()
  let tool_defs = tools.list_tools()
  for tool in tool_defs {
    match tool.provenance {
      Some(s) => assert_eq(s, "posoco_ext_bash")
      None => fail("expected provenance to be set")
    }
  }
}

///|
test "extract_command_from_cmd_key" {
  let args = Json::object(
    Map::from_array([
      ("cmd", Json::string("ls -la")),
      ("dir", Json::string("/tmp")),
    ]),
  )
  let cmd = extract_command(args)
  assert_eq(cmd, "ls -la")
}

///|
test "extract_command_from_command_key" {
  let args = Json::object(
    Map::from_array([("command", Json::string("git status"))]),
  )
  let cmd = extract_command(args)
  assert_eq(cmd, "git status")
}

///|
/// A missing cmd/command raises a typed error instead of silently falling
/// back to running the JSON blob as a shell command.
async test "extract_command_empty_object_raises_typed_error" {
  let args = Json::object(Map::from_array([]))
  let result = Ok(extract_command(args)) catch { e => Err(e) }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("missing"))
    _ => fail("expected UnknownTool error for missing cmd")
  }
}

///|
async test "extract_command_wrong_type_raises_precise_error" {
  for
    pair in [
      ("cmd", Json::object(Map::from_array([("cmd", Json::number(1.0))]))),
      (
        "command",
        Json::object(Map::from_array([("command", Json::boolean(true))])),
      ),
    ] {
    let (field, args) = pair
    let result = Ok(extract_command(args)) catch { error => Err(error) }
    match result {
      Err(@posoco.RuntimeError::UnknownTool(message)) => {
        assert_true(message.contains("'" + field + "'"))
        assert_true(message.contains("must be a string"))
        assert_false(message.contains("missing"))
      }
      _ => fail("expected wrong-type shell command to be rejected")
    }
  }
}

///|
async test "empty_command_is_compact_typed_failure" {
  let ctx : @posoco.ToolCallContext = {
    effect_id: @kernel.EffectId::{ value: 1, },
    call_id: @posoco.CallId::unchecked("tc_empty"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(Map::from_array([("cmd", Json::string(""))])),
    register_cancel: fn(_ : &@posoco.ToolCancellable) { () },
  }
  let result = Ok(ShellTools().execute(ctx)) catch { error => Err(error) }
  match result {
    Err(@posoco.RuntimeError::InvocationFailed(message)) =>
      assert_eq(message, "bash: empty cmd")
    _ => fail("expected empty command to fail before process execution")
  }
}

///|
test "bash_model_output_leaves_short_success_unchanged" {
  assert_eq(bash_model_output("ok\n", 0), "ok\n")
}

///|
test "bash_model_output_reports_nonzero_exit_once" {
  assert_eq(bash_model_output("failed", 7), "exit=7\nfailed")
  assert_eq(bash_model_output("", 2), "exit=2")
}

///|
test "bash_model_output_caps_long_output_and_keeps_head_and_tail" {
  let raw = "HEAD-" + "x".repeat(40_000) + "-TAIL"
  let out = bash_model_output(raw, 0)
  assert_eq(bash_char_count(out), BASH_OUTPUT_CHAR_CAP)
  assert_true(out.has_prefix("HEAD-"))
  assert_true(out.contains("…[cut]…"))
  assert_true(out.has_suffix("-TAIL"))
}

///|
test "bash_model_output_counts_unicode_as_characters" {
  let raw = "头" + "界".repeat(40_000) + "尾"
  let out = bash_model_output(raw, 0)
  assert_eq(bash_char_count(out), BASH_OUTPUT_CHAR_CAP)
  assert_true(out.has_prefix("头"))
  assert_true(out.has_suffix("尾"))
}

///|
test "bash timeout defaults to five minutes" {
  assert_eq(bash_timeout_ms(Json::object(Map::from_array([]))), 300000)
}

///|
test "bash timeout accepts valid hard deadlines" {
  for n in [1, 10000, 300000, 3600000] {
    let args = Json::object(
      Map::from_array([("timeout_ms", Json::number(n.to_double()))]),
    )
    assert_eq(bash_timeout_ms(args), n)
  }
}

///|
test "bash timeout rejects malformed or unsafe values" {
  let candidates = [
    Json::number(0.0),
    Json::number(-1.0),
    Json::number(3600001.0),
    Json::number(3.5),
    Json::string("forever"),
    Json::boolean(true),
    Json::null(),
  ]
  for bad in candidates {
    let args = Json::object(Map::from_array([("timeout_ms", bad)]))
    let result = Ok(bash_timeout_ms(args)) catch { error => Err(error) }
    match result {
      Err(@posoco.RuntimeError::UnknownTool(message)) =>
        assert_true(message.contains("timeout_ms"))
      _ => fail("expected invalid timeout to be rejected")
    }
  }
}

///|
test "bash session argument validation" {
  assert_false(bash_background_requested(Json::object(Map::from_array([]))))
  assert_true(
    bash_background_requested(
      Json::object(Map::from_array([("background", Json::boolean(true))])),
    ),
  )
  assert_eq(
    bash_field_int(Json::object(Map::from_array([])), "yield_time_ms", 0, 60000),
    0,
  )
}

///|
test "bash session cursors expose bounded incremental output" {
  let session : ShellSession = {
    id: "probe",
    effect_id: @kernel.EffectId::{ value: -10, },
    started_at_ms: @async.now(),
    last_output_at_ms: @async.now(),
    ended_at_ms: None,
    status: "running",
    output: "",
    base_cursor: 0L,
    next_cursor: 0L,
    outcome: None,
    exit_code: None,
    worker: None,
    kill_requested: false,
  }
  session.append("abc")
  let snapshot = session.snapshot(1L)
  match snapshot {
    Json::Object(fields) => {
      assert_eq(fields["output"], Json::string("bc"))
      assert_eq(fields["cursor"], Json::number(3.0))
    }
    _ => fail("expected session snapshot object")
  }
  session.append("x".repeat(40000))
  assert_true(bash_char_count(session.output) <= BASH_OUTPUT_CHAR_CAP)
  assert_true(session.base_cursor > 0L)
}

///|
fn bash_session_test_ctx(
  tool : String,
  arguments : Json,
  number : Int32,
) -> @posoco.ToolCallContext {
  {
    effect_id: @kernel.EffectId::{ value: number, },
    call_id: @posoco.CallId::unchecked("tc_background"),
    name: @posoco.ToolName::unchecked(tool),
    arguments,
    register_cancel: fn(_ : &@posoco.ToolCancellable) { () },
  }
}

///|
async test "bash session: background returns id and can be polled to completion" {
  @async.with_task_group(async fn(group) {
    let bash = ShellTools()
    bash.attach(group)
    let arguments = Json::object(
      Map::from_array([
        ("cmd", Json::string("sleep 1; echo background-done")),
        ("yield_time_ms", Json::number(10.0)),
        ("timeout_ms", Json::number(4000.0)),
      ]),
    )
    let result = bash.execute(bash_session_test_ctx("bash", arguments, 991))
    let id = match result {
      @posoco.ToolOutcome::Success(content~, ..) => {
        let json = @json.parse(content) catch { _ => Json::null() }
        match json {
          Json::Object(fields) =>
            match fields.get("session_id") {
              Some(Json::String(value)) => value
              _ => fail("missing session id")
            }
          _ => fail("not a session snapshot")
        }
      }
      _ => fail("expected background session")
    }
    let waited = bash.execute(
      bash_session_test_ctx(
        "bash_wait",
        Json::object(
          Map::from_array([
            ("session_id", Json::string(id)),
            ("timeout_ms", Json::number(3000.0)),
          ]),
        ),
        992,
      ),
    )
    match waited {
      @posoco.ToolOutcome::Success(content~, ..) => {
        assert_true(content.contains("background-done"))
        assert_true(content.contains("completed"))
      }
      _ => fail("expected completed session snapshot")
    }
    bash.shutdown()
  })
}

///|
async test "bash: hard deadline terminates a sleeping child" {
  let bash = ShellTools()
  let outcome = bash.execute(
    bash_session_test_ctx(
      "bash",
      Json::object(
        Map::from_array([
          ("cmd", Json::string("sleep 20")),
          ("timeout_ms", Json::number(150.0)),
        ]),
      ),
      993,
    ),
  )
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("timed out after 150ms"))
    _ => fail("expected timeout tool error")
  }
}

///|
async test "bash: background requires an explicit host owner" {
  let bash = ShellTools()
  let attempted = Ok(
    bash.execute(
      bash_session_test_ctx(
        "bash",
        Json::object(
          Map::from_array([
            ("cmd", Json::string("sleep 20")),
            ("background", Json::boolean(true)),
          ]),
        ),
        994,
      ),
    ),
  ) catch {
    error => Err(error)
  }
  match attempted {
    Err(@posoco.RuntimeError::InvocationFailed(message)) =>
      assert_true(message.contains("attach"))
    _ => fail("expected rejection without host task group")
  }
}

///|
async test "bash: large output is drained without blocking" {
  let bash = ShellTools()
  let result = bash.execute(
    bash_session_test_ctx(
      "bash",
      Json::object(
        Map::from_array([
          (
            "cmd",
            Json::string("awk 'BEGIN { for(i=0;i<60000;i++) print \"x\" }'"),
          ),
          ("timeout_ms", Json::number(10000.0)),
        ]),
      ),
      995,
    ),
  )
  match result {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(bash_char_count(content) <= BASH_OUTPUT_CHAR_CAP)
    _ => fail("large output should not cause a deadlock")
  }
}

///|
test "shell timeout provenance cannot be forged by ordinary command output" {
  let forged = @posoco.ToolOutcome::ToolReportedError(
    content="bash: timed out after 100ms",
    structured=None,
  )
  assert_false(bash_outcome_timed_out(forged))
  let actual = @posoco.ToolOutcome::ToolReportedError(
    content="bash: timed out after 100ms",
    structured=Some(bash_timeout_detail(100)),
  )
  assert_true(bash_outcome_timed_out(actual))
}

///|
test "stopping sessions still occupy capacity and require settlement" {
  let now = @async.now()
  let bash = ShellTools()
  for i in 0..<BASH_MAX_RUNNING_SESSIONS {
    let id = "s" + i.to_string()
    let session : ShellSession = {
      id,
      effect_id: @kernel.EffectId::{ value: 1000 + i },
      started_at_ms: now,
      last_output_at_ms: now,
      ended_at_ms: None,
      status: "stopping",
      output: "",
      base_cursor: 0L,
      next_cursor: 0L,
      outcome: None,
      exit_code: None,
      worker: None,
      kill_requested: true,
    }
    bash.sessions[id] = session
    assert_true(session.active())
  }
  assert_false(bash.session_capacity())
}

///|
async test "bash wait does not claim a stopping session is finished" {
  let now = @async.now()
  let bash = ShellTools()
  let session : ShellSession = {
    id: "stopping",
    effect_id: @kernel.EffectId::{ value: 1001 },
    started_at_ms: now,
    last_output_at_ms: now,
    ended_at_ms: None,
    status: "stopping",
    output: "",
    base_cursor: 0L,
    next_cursor: 0L,
    outcome: None,
    exit_code: None,
    worker: None,
    kill_requested: true,
  }
  bash.sessions["stopping"] = session
  let before = @async.now()
  ignore(bash.execute(bash_session_test_ctx(
    "bash_wait",
    Json::object(Map::from_array([
      ("session_id", Json::string("stopping")),
      ("timeout_ms", Json::number(100.0)),
    ])),
    1091,
  )))
  assert_true(@async.now() - before >= 50L)
}

///|
async test "bash large output retains the final diagnostic" {
  let bash = ShellTools()
  let result = bash.execute(bash_session_test_ctx(
    "bash",
    Json::object(Map::from_array([
      ("cmd", Json::string("awk 'BEGIN { for (i=0; i<50000; i++) print \"noise\"; print \"FINAL_DIAGNOSTIC_012345\" }'")),
      ("timeout_ms", Json::number(10000.0)),
    ])),
    1092,
  ))
  match result {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("FINAL_DIAGNOSTIC_012345"))
    _ => fail("flooded command should finish successfully")
  }
}
