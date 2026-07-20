///|
/// rtk_hook_test.mbt — Tests for RTKHook
///
/// Note: Tests use a mock rewrite function (not the default stub) so they
/// don't require the `rtk` binary to be installed.

///|

///|
/// ——— Test: is_shell_tool ———
test "is_shell_tool_recognizes_shells" {
  let tools = default_shell_tools()
  assert_true(is_shell_tool("bash", tools))
  assert_true(is_shell_tool("sh", tools))
  assert_true(is_shell_tool("zsh", tools))
  assert_true(is_shell_tool("shell", tools))
  assert_true(is_shell_tool("cmd", tools))
}

///|
test "is_shell_tool_rejects_non_shells" {
  let tools = default_shell_tools()
  assert_false(is_shell_tool("echo", tools))
  assert_false(is_shell_tool("ls", tools))
  assert_false(is_shell_tool("cat", tools))
  assert_false(is_shell_tool("python", tools))
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
  match extract_command(args) {
    Ok(cmd) => assert_eq(cmd, "ls -la")
    Err(_) => fail("expected valid cmd")
  }
}

///|
test "extract_command_from_command_key" {
  let args = Json::object(
    Map::from_array([("command", Json::string("git status"))]),
  )
  match extract_command(args) {
    Ok(cmd) => assert_eq(cmd, "git status")
    Err(_) => fail("expected valid command")
  }
}

///|
test "extract_command_unknown_key_is_loud_without_raw_json" {
  let args = Json::object(
    Map::from_array([("script", Json::string("echo hi"))]),
  )
  match extract_command(args) {
    Err(@posoco.HookError::Aborted(message)) => {
      assert_true(message.contains("require"))
      assert_true(!message.contains("echo hi"))
    }
    _ => fail("expected strict missing-command error")
  }
}

///|
test "extract_command_non_object_is_loud_without_raw_json" {
  let args = Json::string("ls -la")
  match extract_command(args) {
    Err(@posoco.HookError::Aborted(message)) => {
      assert_true(message.contains("JSON object"))
      assert_true(!message.contains("ls -la"))
    }
    _ => fail("expected strict non-object error")
  }
}

///|
test "extract_command_wrong_type_is_loud_without_raw_json" {
  let args = Json::object(
    Map::from_array([("cmd", Json::array([Json::string("secret")]))]),
  )
  match extract_command(args) {
    Err(@posoco.HookError::Aborted(message)) => {
      assert_true(message.contains("must be a string"))
      assert_true(!message.contains("secret"))
    }
    _ => fail("expected strict command type error")
  }
}

///|
/// ——— Test: rewrite_tool_call ———
test "rewrite_tool_call_updates_cmd_arg" {
  let original = @posoco.ToolCall::{
    id: "call_1",
    name: "bash",
    arguments: Json::object(Map::from_array([("cmd", Json::string("ls -la"))])),
  }
  let rewritten = rewrite_tool_call(original, "rtk ls -la")
  match rewritten.arguments {
    Object(map) =>
      match map.get("cmd") {
        Some(String(s)) => assert_eq(s, "rtk ls -la")
        _ => fail("expected cmd field")
      }
    _ => fail("expected Object")
  }
}

///|
test "rewrite_tool_call_does_not_mutate_original_arguments" {
  let original_map : Map[String, Json] = Map::from_array([
    ("cmd", Json::string("ls -la")),
  ])
  let original = @posoco.ToolCall::{
    id: "call_snapshot",
    name: "bash",
    arguments: Json::object(original_map),
  }
  let _ = rewrite_tool_call(original, "rtk ls -la")
  assert_true(original_map["cmd"] == Json::string("ls -la"))
}

///|
test "rewrite_tool_call_preserves_id_and_name" {
  let original = @posoco.ToolCall::{
    id: "call_42",
    name: "sh",
    arguments: Json::object(
      Map::from_array([("cmd", Json::string("make build"))]),
    ),
  }
  let rewritten = rewrite_tool_call(original, "rtk make build")
  assert_eq(rewritten.id, "call_42")
  assert_eq(rewritten.name, "sh")
}

///|
/// ——— Test: RTKHook PipelineHook implementation ———
async test "hook_passes_through_non_shell_tool" {
  // Setup: a rewrite that would change anything
  let hook = RTKHook::new("/usr/local/bin/rtk", fn(cmd) { Some("rtk " + cmd) })
  let stage = @posoco.Stage::BeforeTool({
    id: "call_1",
    name: "echo", // not a shell tool
    arguments: Json::null(),
  })
  match hook.on_stage(stage) {
    Ok(s) => assert_true(s is @posoco.Stage::BeforeTool(_))
    Err(_) => fail("expected Ok")
  }
}

///|
async test "hook_rewrites_shell_tool_call" {
  // Mock rewrite that prepends "rtk "
  let hook = RTKHook::new("/usr/local/bin/rtk", fn(cmd) { Some("rtk " + cmd) })
  let stage = @posoco.Stage::BeforeTool({
    id: "call_1",
    name: "bash",
    arguments: Json::object(Map::from_array([("cmd", Json::string("ls -la"))])),
  })
  match hook.on_stage(stage) {
    Ok(@posoco.Stage::BeforeTool(call)) =>
      // Should have been rewritten
      match call.arguments {
        Object(map) =>
          match map.get("cmd") {
            Some(String(s)) => assert_eq(s, "rtk ls -la")
            _ => fail("expected cmd field")
          }
        _ => fail("expected Object")
      }
    Ok(_) => fail("expected BeforeTool stage")
    Err(_) => fail("expected Ok")
  }
}

///|
async test "hook_passes_through_when_rewrite_returns_none" {
  // Mock rewrite that always returns None (pass-through)
  let hook = RTKHook::new("/usr/local/bin/rtk", fn(_cmd) { None })
  let stage = @posoco.Stage::BeforeTool({
    id: "call_1",
    name: "bash",
    arguments: Json::object(Map::from_array([("cmd", Json::string("ls -la"))])),
  })
  match hook.on_stage(stage) {
    Ok(s) =>
      // Stage should be unchanged (pass-through)
      assert_true(s is @posoco.Stage::BeforeTool(_))
    Err(_) => fail("expected Ok")
  }
}

///|
async test "hook_passes_through_after_tool_stage" {
  let hook = RTKHook::new("/usr/local/bin/rtk", fn(cmd) { Some("rtk " + cmd) })
  let stage = @posoco.Stage::AfterTurn(@posoco.TurnResult::{
    message: @posoco.Message::{
      role: @posoco.Role::Assistant,
      content: [],
      tool_calls: [],
      tool_call_id: None,
      name: None,
      reasoning_content: None,
    },
    tool_results: [],
    final_session_id: "session_1",
  })
  match hook.on_stage(stage) {
    Ok(s) => assert_true(s is @posoco.Stage::AfterTurn(_))
    Err(_) => fail("expected Ok")
  }
}

///|
async test "hook_passes_through_before_turn_stage" {
  let hook = RTKHook::new("/usr/local/bin/rtk", fn(cmd) { Some("rtk " + cmd) })
  match hook.on_stage(@posoco.Stage::BeforeTurn) {
    Ok(@posoco.Stage::BeforeTurn) => ()
    _ => fail("expected BeforeTurn to pass through")
  }
}

///|
async test "hook_identical_rewrite_passes_through" {
  // Rewrite function returns the same string (no actual rewrite)
  let hook = RTKHook::new(
    "/usr/local/bin/rtk",
    fn(cmd) { Some(cmd) }, // returns identical command
  )
  let stage = @posoco.Stage::BeforeTool({
    id: "call_1",
    name: "bash",
    arguments: Json::object(Map::from_array([("cmd", Json::string("ls -la"))])),
  })
  match hook.on_stage(stage) {
    Ok(s) =>
      // Should pass through unchanged since rewrite output == original
      assert_true(s is @posoco.Stage::BeforeTool(_))
    Err(_) => fail("expected Ok")
  }
}
