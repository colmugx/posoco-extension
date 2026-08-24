///|
/// rtk_hook_test.mbt — Tests for RTKHook
///
/// Note: Tests use a mock rewrite function (not the default stub) so they
/// don't require the `rtk` binary to be installed.

///|

///|
/// Test: is_shell_tool
test "is_shell_tool_recognizes_shells" {
  let tools = default_shell_tools()
  assert_true(is_shell_tool(@posoco.ToolName::unchecked("bash"), tools))
  assert_true(is_shell_tool(@posoco.ToolName::unchecked("sh"), tools))
  assert_true(is_shell_tool(@posoco.ToolName::unchecked("zsh"), tools))
  assert_true(is_shell_tool(@posoco.ToolName::unchecked("shell"), tools))
  assert_true(is_shell_tool(@posoco.ToolName::unchecked("cmd"), tools))
}

///|
test "is_shell_tool_rejects_non_shells" {
  let tools = default_shell_tools()
  assert_false(is_shell_tool(@posoco.ToolName::unchecked("echo"), tools))
  assert_false(is_shell_tool(@posoco.ToolName::unchecked("ls"), tools))
  assert_false(is_shell_tool(@posoco.ToolName::unchecked("cat"), tools))
  assert_false(is_shell_tool(@posoco.ToolName::unchecked("python"), tools))
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
test "extract_command_unknown_key_is_loud_without_raw_json" {
  let args = Json::object(
    Map::from_array([("script", Json::string("echo hi"))]),
  )
  let result = Ok(extract_command(args)) catch { error => Err(error) }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(message)) => {
      assert_true(message.contains("require"))
      assert_true(!message.contains("echo hi"))
    }
    _ => fail("expected strict missing-command error")
  }
}

///|
test "extract_command_non_object_is_loud_without_raw_json" {
  let args = Json::string("ls -la")
  let result = Ok(extract_command(args)) catch { error => Err(error) }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(message)) => {
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
  let result = Ok(extract_command(args)) catch { error => Err(error) }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(message)) => {
      assert_true(message.contains("must be a string"))
      assert_true(!message.contains("secret"))
    }
    _ => fail("expected strict command type error")
  }
}

///|
/// Test: rewrite_tool_call
test "rewrite_tool_call_updates_cmd_arg" {
  let original = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked("bash"),
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
    call_id: @posoco.CallId::unchecked("call_snapshot"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(original_map),
  }
  let _ = rewrite_tool_call(original, "rtk ls -la")
  assert_true(original_map["cmd"] == Json::string("ls -la"))
}

///|
test "rewrite_tool_call_preserves_id_and_name" {
  let original = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_42"),
    name: @posoco.ToolName::unchecked("sh"),
    arguments: Json::object(
      Map::from_array([("cmd", Json::string("make build"))]),
    ),
  }
  let rewritten = rewrite_tool_call(original, "rtk make build")
  assert_eq(rewritten.call_id.to_string(), "call_42")
  assert_eq(rewritten.name.to_string(), "sh")
}

///|
/// Test: RTKHook Hook implementation
async test "hook_passes_through_non_shell_tool" {
  // Setup: a rewrite that would change anything
  let hook = RTKHook("/usr/local/bin/rtk", fn(cmd) { Some("rtk " + cmd) })
  let call = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked("echo"), // not a shell tool
    arguments: Json::null(),
  }
  match hook.before_tool(call) {
    Approve(_) => () // pass-through approve
    other => fail("expected Approve, got " + other.to_string())
  }
}

///|
async test "hook_rewrites_shell_tool_call" {
  // Mock rewrite that prepends "rtk "
  let hook = RTKHook("/usr/local/bin/rtk", fn(cmd) { Some("rtk " + cmd) })
  let call = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(Map::from_array([("cmd", Json::string("ls -la"))])),
  }
  match hook.before_tool(call) {
    Approve(call~) =>
      // Should have been rewritten
      match call.arguments {
        Object(map) =>
          match map.get("cmd") {
            Some(String(s)) => assert_eq(s, "rtk ls -la")
            _ => fail("expected cmd field")
          }
        _ => fail("expected Object")
      }
    other =>
      fail("expected Approve with rewritten call, got " + other.to_string())
  }
}

///|
async test "hook_passes_through_when_rewrite_returns_none" {
  // Mock rewrite that always returns None (pass-through)
  let hook = RTKHook("/usr/local/bin/rtk", fn(_cmd) { None })
  let call = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(Map::from_array([("cmd", Json::string("ls -la"))])),
  }
  match hook.before_tool(call) {
    Approve(call~) =>
      // Call should be unchanged (pass-through)
      assert_eq(call.call_id.to_string(), "call_1")
    other => fail("expected Approve pass-through, got " + other.to_string())
  }
}

///|
test "manifest_registers_as_extension_with_hook" {
  let hook = RTKHook("rtk", fn(cmd) { default_rtk_rewrite("rtk", cmd) })
  assert_eq(hook.extension_id(), "posoco_ext_rtk")
  let manifest = hook.manifest()
  assert_eq(manifest.hooks.length(), 1)
}

///|
async test "hook_identical_rewrite_passes_through" {
  // Rewrite function returns the same string (no actual rewrite)
  let hook = RTKHook(
    "/usr/local/bin/rtk",
    fn(cmd) { Some(cmd) }, // returns identical command
  )
  let call = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(Map::from_array([("cmd", Json::string("ls -la"))])),
  }
  match hook.before_tool(call) {
    Approve(call~) =>
      // Should pass through unchanged since rewrite output == original
      assert_eq(call.call_id.to_string(), "call_1")
    other => fail("expected Approve pass-through, got " + other.to_string())
  }
}
