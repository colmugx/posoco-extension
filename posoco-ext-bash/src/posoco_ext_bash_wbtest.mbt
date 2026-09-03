///|
/// shell_wbtest.mbt — Whitebox tests for ShellTools (unified ToolProvider)
///
/// Runtime fixtures use only the local `sh` required by the implementation;
/// they are offline and do not depend on external services.

///|
/// Test: ShellTools.list_tools
async test "list_tools_contains_bash" {
  let tools = ShellTools()
  let tool_defs = tools.list_tools()
  let names = tool_defs.map(fn(t) { t.name.to_string() })
  assert_true(names.contains("bash"))
  assert_eq(tool_defs.length(), 1)
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
/// Test: extract_command
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
async test "empty_command_has_arguments_stage" {
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("tc_empty"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(Map::from_array([("cmd", Json::string(""))])),
  }
  let result = Ok(ShellTools().execute("bash", call)) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.RuntimeError::InvocationFailed(message)) => {
      assert_true(message.contains("bash"))
      assert_true(message.contains("stage=arguments"))
      assert_true(message.contains("empty_command"))
    }
    _ => fail("expected empty command to fail before process execution")
  }
}
