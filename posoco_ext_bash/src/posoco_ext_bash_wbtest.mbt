///|
/// shell_wbtest.mbt — Whitebox tests for ShellTools (unified ToolProvider)
///
/// Note: Runtime execution tests are skipped since they need a real shell.

///|
/// ——— Test: ShellTools.list_tools ———
async test "list_tools_contains_bash_and_shell" {
  let tools = ShellTools::{  }
  let tool_defs = tools.list_tools()
  let names = tool_defs.map(fn(t) { t.name })
  assert_true(names.contains("bash"))
  assert_true(names.contains("shell"))
  assert_eq(tool_defs.length(), 2)
}

///|
async test "list_tools_tool_defs_have_descriptions" {
  let tools = ShellTools::{  }
  let tool_defs = tools.list_tools()
  for tool in tool_defs {
    assert_true(tool.description.length() > 0)
  }
}

///|
async test "list_tools_tool_defs_have_input_schema" {
  let tools = ShellTools::{  }
  let tool_defs = tools.list_tools()
  for tool in tool_defs {
    assert_true(tool.input_schema is Json::Object(_))
  }
}

///|
async test "list_tools_have_source" {
  let tools = ShellTools::{  }
  let tool_defs = tools.list_tools()
  for tool in tool_defs {
    match tool.source {
      Some(s) => assert_eq(s, "posoco_ext_bash")
      None => fail("expected source to be set")
    }
  }
}

///|
/// ——— Test: extract_command ———
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
test "extract_command_empty_object_returns_to_string" {
  let args = Json::object(Map::from_array([]))
  let cmd = extract_command(args)
  assert_true(cmd.length() > 0)
}
