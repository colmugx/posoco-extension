///|
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
async test "hook_passes_through_non_shell_tool" {
  let hook = RTKHook("rtk")
  let call = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked("echo"),
    arguments: Json::null(),
  }
  match hook.before_tool(call) {
    Approve(_) => ()
    other => fail("expected Approve, got " + other.to_string())
  }
}

///|
/// Scripted rewrite seam: maps exact commands to canned rewrites; any other
/// command yields None (the no-equivalent/no-rtk outcome). No process spawns.
priv struct FakeRtkRewrite {
  rewrites : Map[String, String]
}

///|
impl RTKRewrite for FakeRtkRewrite with fn rewrite(
  self : FakeRtkRewrite,
  _rtk_path : String,
  cmd : String,
) -> String? {
  self.rewrites.get(cmd)
}

///|
async test "hook_rewrites_shell_tool_call" {
  let fake : FakeRtkRewrite = {
    rewrites: Map::from_array([("git status", "rtk git status")]),
  }
  let hook = RTKHook("rtk")
  let call = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(
      Map::from_array([("cmd", Json::string("git status"))]),
    ),
  }
  match before_tool_impl(fake, hook, call) {
    Approve(call~) =>
      match call.arguments {
        Object(map) =>
          match map.get("cmd") {
            Some(String(s)) => assert_eq(s, "rtk git status")
            _ => fail("expected cmd field")
          }
        _ => fail("expected Object")
      }
    other =>
      fail("expected Approve with rewritten call, got " + other.to_string())
  }
}

///|
/// With a rewriter that has no entry for the command (the no-equivalent and
/// no-rtk-binary outcomes), the call passes through unchanged.
async test "hook_passes_through_when_no_rtk_equivalent" {
  let fake : FakeRtkRewrite = { rewrites: Map::from_array([]), }
  let hook = RTKHook("rtk")
  let call = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(
      Map::from_array([("cmd", Json::string("echo rtk_no_equivalent_probe"))]),
    ),
  }
  match before_tool_impl(fake, hook, call) {
    Approve(call~) =>
      match call.arguments {
        Object(map) =>
          match map.get("cmd") {
            Some(String(s)) => assert_eq(s, "echo rtk_no_equivalent_probe")
            _ => fail("expected cmd field")
          }
        _ => fail("expected Object")
      }
    other => fail("expected Approve pass-through, got " + other.to_string())
  }
}

///|
async test "hook_rejects_malformed_shell_args" {
  let hook = RTKHook("rtk")
  let call = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::null(), // not a JSON object
  }
  match hook.before_tool(call) {
    Reject(reason~) => assert_true(reason.contains("rtk"))
    other => fail("expected Reject, got " + other.to_string())
  }
}

///|
test "manifest_registers_as_extension_with_hook" {
  let hook = RTKHook("rtk")
  assert_eq(hook.extension_id(), "posoco_ext_rtk")
  let manifest = hook.manifest()
  assert_eq(manifest.hooks.length(), 1)
}

///|
async test "hook_ignores_the_gateway_envelope_and_judges_the_child" {
  let hook = RTKHook("rtk")
  // The gateway envelope is not a shell call: rtk leaves it to the gateway,
  // and the shell child it declares comes back through this hook by name.
  let envelope = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_g"),
    name: @posoco.ToolName::unchecked("tool_execute"),
    arguments: Json::object(
      Map::from_array([
        ("tool", Json::string("bash")),
        (
          "arguments",
          Json::object(Map::from_array([("cmd", Json::string("ls"))])),
        ),
      ]),
    ),
  }
  match hook.before_tool(envelope) {
    Approve(_) => ()
    other =>
      fail(
        "expected Approve for the gateway envelope, got " + other.to_string(),
      )
  }
  // A malformed shell child is still rejected loudly under its own name.
  let malformed = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_g2"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(Map::from_array([])),
  }
  match hook.before_tool(malformed) {
    Reject(_) => ()
    other =>
      fail(
        "expected Reject for a malformed shell child, got " + other.to_string(),
      )
  }
}

///|
test "deferred_shell_child_call_is_rewritten_in_place" {
  // A deferred shell call reaches the hook as its own child call: the real
  // name and arguments are already on the call, so the rewrite stays local.
  let child_call = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_g3"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(
      Map::from_array([
        ("cmd", Json::string("git status")),
        ("timeout", Json::number(5.0)),
      ]),
    ),
  }
  let rewritten = rewrite_tool_call(child_call, "rtk git status")
  assert_eq(rewritten.name.to_string(), "bash")
  assert_eq(rewritten.call_id.to_string(), "call_g3")
  match rewritten.arguments {
    Object(args) => {
      assert_eq(args.get("cmd"), Some(Json::string("rtk git status")))
      assert_eq(args.get("timeout"), Some(Json::number(5.0)))
    }
    _ => fail("expected an arguments object")
  }
}
