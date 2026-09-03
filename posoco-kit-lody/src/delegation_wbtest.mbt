// delegation_wbtest.mbt — intent-to-call mapping, the unified dual-track
// status view, and posoco tool-call materialization.

///|
test "intent maps onto lody create and chat calls" {
  let intent : DelegationIntent = {
    task: "fix the flaky test",
    cwd: Some("/work"),
    model: None,
    prompt: Some("run the suite and fix"),
  }
  let create = lody_create_call(intent, task_id="t-1")
  inspect(create.tool, content="lody_session_create")
  inspect(
    create.arguments.stringify(),
    content="{\"taskId\":\"t-1\",\"objective\":\"fix the flaky test\",\"cwd\":\"/work\"}",
  )
  let bare : DelegationIntent = {
    task: "triage the backlog",
    cwd: None,
    model: None,
    prompt: None,
  }
  let bare_create = lody_create_call(bare, task_id="t-2")
  assert_false(bare_create.arguments.stringify().contains("cwd"))
  let chat = lody_chat_call(intent, lody_session_id="ls-9")
  inspect(chat.tool, content="lody_session_chat")
  inspect(
    chat.arguments.stringify(),
    content="{\"sessionId\":\"ls-9\",\"prompt\":\"run the suite and fix\"}",
  )
  // without a full prompt the one-line task is the instruction
  let bare_chat = lody_chat_call(bare, lody_session_id="ls-8")
  inspect(
    bare_chat.arguments.stringify(),
    content="{\"sessionId\":\"ls-8\",\"prompt\":\"triage the backlog\"}",
  )
  // emitted calls are recognized by the detector
  assert_true(is_lody_tool_name(create.tool))
  assert_true(is_lody_tool_name(chat.tool))
}

///|
test "phase mapping spans both disjoint status vocabularies" {
  assert_eq(phase_of_task_status(@lody.LodyTaskStatus::Pending), Queued)
  assert_eq(phase_of_task_status(@lody.LodyTaskStatus::InProgress), Running)
  assert_eq(phase_of_task_status(@lody.LodyTaskStatus::Completed), Succeeded)
  assert_eq(phase_of_task_status(@lody.LodyTaskStatus::Failed), Failed)
  assert_eq(
    phase_of_subagent_status(@lody.LodySubagentStatus::Running),
    Running,
  )
  assert_eq(
    phase_of_subagent_status(@lody.LodySubagentStatus::Completed),
    Succeeded,
  )
  assert_eq(phase_of_subagent_status(@lody.LodySubagentStatus::Failed), Failed)
  assert_eq(
    phase_of_subagent_status(@lody.LodySubagentStatus::TimedOut),
    Failed,
  )
  assert_eq(phase_of_subagent_status(@lody.LodySubagentStatus::Killed), Failed)
  assert_eq(phase_of_subagent_status(@lody.LodySubagentStatus::Lost), Lost)
}

///|
test "task-track phase parses from _meta or from the lody envelope itself" {
  let wrapped = @json.parse(
    "{\"lody\": {\"task\": {\"version\": 1, \"taskId\": \"t-1\", \"kind\": \"background\", \"status\": \"in_progress\"}}}",
  )
  assert_eq(parse_task_phase(wrapped), Ok(Some(Running)))
  let direct = @json.parse(
    "{\"task\": {\"version\": 1, \"taskId\": \"t-1\", \"kind\": \"scheduled\", \"status\": \"failed\"}}",
  )
  assert_eq(parse_task_phase(direct), Ok(Some(Failed)))
  let no_task = @json.parse("{\"lody\": {\"turnId\": \"x\"}}")
  assert_eq(parse_task_phase(no_task), Ok(None))
  guard parse_task_phase(
      @json.parse(
        "{\"lody\": {\"task\": {\"version\": 2, \"taskId\": \"t\", \"kind\": \"background\", \"status\": \"failed\"}}}",
      ),
    )
    is Err(message) else {
    fail("expected Err")
  }
  inspect(
    message,
    content="lody.sessionMeta: field \"task\": lody.task: unsupported version 2 (expected 1)",
  )
  guard parse_task_phase(@json.parse("[]")) is Err(message) else {
    fail("expected Err")
  }
  inspect(message, content="lody: delegation status must be a JSON object")
}

///|
test "subagent-track phase parses a list row" {
  let row = @json.parse(
    "{\"taskId\": \"s-1\", \"description\": \"refactor\", \"status\": \"timed_out\", \"startedAtEpochSeconds\": 1700000000, \"endedAtEpochSeconds\": null}",
  )
  assert_eq(parse_subagent_phase(row), Ok(Failed))
  guard parse_subagent_phase(@json.parse("{\"taskId\": \"s-2\"}"))
    is Err(message) else {
    fail("expected Err")
  }
  inspect(
    message,
    content="lody.subagents.task: missing required field \"description\"",
  )
}

///|
test "delegation calls materialize as validated posoco tool calls" {
  let call : DelegationCall = {
    tool: LODY_MCP_SESSION_CHAT,
    arguments: @json.parse("{}"),
  }
  guard call.to_tool_call(call_id="c-1") is Ok(tc) else { fail("expected Ok") }
  inspect(tc.call_id.value, content="c-1")
  inspect(tc.name.value, content="lody_session_chat")
  guard call.to_tool_call(call_id="") is Err(message) else {
    fail("expected Err")
  }
  inspect(message, content="invalid call id: CallId must be non-empty")
}
