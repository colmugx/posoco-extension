///|
/// Pure-function coverage for argument parsing and outcome formatting.

///|
fn tool_args_of(text : String) -> Json raise {
  @json.parse(text) catch {
    err => fail(err.to_string())
  }
}

///|
test "parse_missing_task_errs" {
  let arguments = tool_args_of(
    (
      #|{"cwd": "/tmp"}
    ),
  )
  match zcode_parse_args(arguments, default_mode="edit") {
    Err(message) => assert_true(message.contains("task"))
    Ok(_) => fail("expected missing task to be rejected")
  }
}

///|
test "parse_empty_task_errs" {
  let arguments = tool_args_of(
    (
      #|{"task": ""}
    ),
  )
  match zcode_parse_args(arguments, default_mode="edit") {
    Err(message) => assert_true(message.contains("non-empty"))
    Ok(_) => fail("expected empty task to be rejected")
  }
}

///|
test "parse_non_object_arguments_err" {
  match zcode_parse_args(Json::string("do it"), default_mode="edit") {
    Err(_) => ()
    Ok(_) => fail("expected non-object arguments to be rejected")
  }
}

///|
test "parse_invalid_mode_errs" {
  let arguments = tool_args_of(
    (
      #|{"task": "do it", "mode": "agentic"}
    ),
  )
  match zcode_parse_args(arguments, default_mode="edit") {
    Err(message) => {
      assert_true(message.contains("agentic"))
      assert_true(message.contains("build|edit|plan|yolo"))
    }
    Ok(_) => fail("expected invalid mode to be rejected")
  }
}

///|
test "parse_defaults_apply" {
  let arguments = tool_args_of(
    (
      #|{"task": "do it"}
    ),
  )
  match zcode_parse_args(arguments, default_mode="edit") {
    Ok(args) => {
      assert_eq(args.task, "do it")
      assert_true(args.cwd is None)
      assert_true(args.session_id is None)
      assert_eq(args.mode, Some("edit"))
    }
    Err(message) => fail(message)
  }
}

///|
test "parse_full_args" {
  let arguments = tool_args_of(
    (
      #|{"task": "fix the bug", "cwd": "/repo", "session_id": "sess_abc", "mode": "plan"}
    ),
  )
  match zcode_parse_args(arguments, default_mode="edit") {
    Ok(args) => {
      assert_eq(args.task, "fix the bug")
      assert_eq(args.cwd, Some("/repo"))
      assert_eq(args.session_id, Some("sess_abc"))
      assert_eq(args.mode, Some("plan"))
    }
    Err(message) => fail(message)
  }
}

///|
fn tool_result_of(
  stop_reason~ : String,
  final_text~ : String,
  usage~ : ZcodeUsage?,
) -> ZcodeTaskResult {
  { session_id: "sess_1234", title: "t", final_text, stop_reason, usage, }
}

///|
test "format_outcome_success" {
  let outcome = zcode_format_outcome(
    tool_result_of(stop_reason="success", final_text="pong", usage=None),
  )
  match outcome {
    Success(content~, ..) => {
      assert_true(content.has_prefix("pong"))
      assert_true(content.contains("session_id: sess_1234"))
      assert_true(!content.contains("tokens:"))
    }
    _ => fail("expected Success")
  }
}

///|
test "format_outcome_success_with_usage_line" {
  let outcome = zcode_format_outcome(
    tool_result_of(
      stop_reason="success",
      final_text="pong",
      usage=Some({ input_tokens: 28853, output_tokens: 3, total_tokens: 28856, }),
    ),
  )
  match outcome {
    Success(content~, ..) =>
      assert_true(content.contains("tokens: input=28853 output=3 total=28856"))
    _ => fail("expected Success")
  }
}

///|
test "format_outcome_failed_is_reported_error" {
  let outcome = zcode_format_outcome(
    tool_result_of(
      stop_reason="failed",
      final_text="the build is broken",
      usage=None,
    ),
  )
  match outcome {
    ToolReportedError(content~, ..) => {
      assert_true(content.has_prefix("the build is broken"))
      assert_true(content.contains("session_id: sess_1234"))
    }
    _ => fail("expected ToolReportedError")
  }
}

///|
test "format_outcome_permission_denied_is_reported_error" {
  let outcome = zcode_format_outcome(
    tool_result_of(
      stop_reason="permission_denied",
      final_text="done\n\nzcode asked for permission for tool 'bash' and was denied by cetas",
      usage=None,
    ),
  )
  match outcome {
    ToolReportedError(content~, ..) =>
      assert_true(content.contains("permission for tool 'bash'"))
    _ => fail("expected ToolReportedError")
  }
}

///|
test "list_tools_declares_single_zcode_def" {
  let tools = zcode_tools()
  let defs = tools.list_tools()
  assert_eq(defs.length(), 1)
  let def = defs[0]
  assert_eq(def.name.to_string(), "zcode")
  assert_eq(def.provenance, Some("posoco_ext_zcode"))
  let schema = def.input_schema
  assert_true(json_field_string(schema, "type") == Some("object"))
  match json_field(schema, "required") {
    Some(Json::Array(required)) => assert_eq(required.length(), 1)
    _ => fail("expected required task")
  }
}
