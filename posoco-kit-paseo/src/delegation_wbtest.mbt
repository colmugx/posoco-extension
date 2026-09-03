// delegation_wbtest.mbt — intent-to-call assembly, prompt call assembly,
// and the get_agent_status → neutral phase decode.

///|
test "create call carries the task and the present optional fields" {
  let full : @delegation.DelegationIntent = {
    task: "migrate the docs",
    cwd: Some("/work"),
    model: Some("sonnet"),
    prompt: Some("run the suite and fix"),
  }
  let call = paseo_create_call(full)
  inspect(call.tool, content="create_agent")
  inspect(
    call.arguments.stringify(),
    content="{\"task\":\"migrate the docs\",\"cwd\":\"/work\",\"model\":\"sonnet\",\"prompt\":\"run the suite and fix\"}",
  )
  let bare : @delegation.DelegationIntent = {
    task: "triage the backlog",
    cwd: None,
    model: None,
    prompt: None,
  }
  let bare_call = paseo_create_call(bare)
  inspect(
    bare_call.arguments.stringify(),
    content="{\"task\":\"triage the backlog\"}",
  )
  // emitted calls are recognized by the detector
  assert_true(is_paseo_tool_name(call.tool))
}

///|
test "prompt call addresses one child agent" {
  let call = paseo_prompt_call(agent_id="a-7", prompt="continue the migration")
  inspect(call.tool, content="send_agent_prompt")
  inspect(
    call.arguments.stringify(),
    content="{\"agentId\":\"a-7\",\"prompt\":\"continue the migration\"}",
  )
}

///|
test "agent status decodes onto the neutral phase" {
  let parse = (status : String) => {
    parse_agent_phase(
      @json.parse("{\"agentId\": \"a-1\", \"status\": \"\{status}\"}"),
    )
  }
  assert_eq(parse("queued"), Ok(@delegation.DelegationPhase::Queued))
  assert_eq(parse("running"), Ok(@delegation.DelegationPhase::Running))
  assert_eq(parse("completed"), Ok(@delegation.DelegationPhase::Succeeded))
  assert_eq(parse("failed"), Ok(@delegation.DelegationPhase::Failed))
  // both stops are terminal failures
  assert_eq(parse("cancelled"), Ok(@delegation.DelegationPhase::Failed))
  assert_eq(parse("killed"), Ok(@delegation.DelegationPhase::Failed))
}

///|
test "agent status rejects malformed results" {
  guard parse_agent_phase(@json.parse("[]")) is Err(message) else {
    fail("expected Err")
  }
  inspect(message, content="paseo: agent status must be a JSON object")
  guard parse_agent_phase(@json.parse("{\"agentId\": \"a-1\"}")) is Err(message) else {
    fail("expected Err")
  }
  inspect(
    message,
    content="paseo: agent status is missing required field \"status\"",
  )
  guard parse_agent_phase(@json.parse("{\"agentId\": \"a-1\", \"status\": 3}"))
    is Err(message) else {
    fail("expected Err")
  }
  inspect(
    message,
    content="paseo: agent status field \"status\" must be a string",
  )
  guard parse_agent_phase(
      @json.parse("{\"agentId\": \"a-1\", \"status\": \"exploded\"}"),
    )
    is Err(message) else {
    fail("expected Err")
  }
  inspect(message, content="paseo: unknown agent status literal \"exploded\"")
}

///|
test "emitted calls materialize as validated posoco tool calls" {
  let intent : @delegation.DelegationIntent = {
    task: "migrate the docs",
    cwd: None,
    model: None,
    prompt: None,
  }
  let create = paseo_create_call(intent)
  guard create.to_tool_call(call_id="c-1") is Ok(tc) else {
    fail("expected Ok")
  }
  inspect(tc.name.value, content="create_agent")
  let prompt = paseo_prompt_call(agent_id="a-7", prompt="go")
  guard prompt.to_tool_call(call_id="c-2") is Ok(tc) else {
    fail("expected Ok")
  }
  inspect(tc.name.value, content="send_agent_prompt")
}
