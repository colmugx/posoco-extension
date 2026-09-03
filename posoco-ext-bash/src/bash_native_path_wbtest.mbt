///|
/// Native-only white-box tests: these exercise the `@process` execute path
/// (and `bash_collect_output_failure`, which lives in
/// `posoco_ext_bash.native.mbt`), so the js target — where the execute path
/// is the bun runner — excludes this file.
test "collect_output_failure_mapping_is_stage_only" {
  match bash_collect_output_failure() {
    @posoco.RuntimeError::InvocationFailed(message) =>
      assert_eq(message, "bash: process failed (stage=collect_output)")
    _ => fail("expected collect_output mapping to be InvocationFailed")
  }
}

///|
/// Invalid UTF-8 from an exit-0 process is an explicit business error, not a
/// successful result with silently replaced output.
async test "non_utf8_output_is_explicit_tool_error" {
  let tools = ShellTools()
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("tc_binary"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(
      Map::from_array([("cmd", Json::string("printf '\\377'"))]),
    ),
  }
  let result = tools.execute("bash", call)
  // Invalid UTF-8 from an exit-0 process is a business-level error, surfaced
  // as ToolReportedError (not Success).
  match result {
    ToolReportedError(content~, ..) => {
      assert_true(content.contains("bash"))
      assert_true(content.contains("stage=decode_output"))
      assert_true(content.contains("invalid_utf8"))
      assert_true(content.contains("exit_code=0"))
    }
    other =>
      fail(
        "expected ToolReportedError for invalid UTF-8, got " + other.to_string(),
      )
  }
}

///|
/// An anchored shell always starts in the anchor root — `pwd` must report it
/// regardless of the host process working directory. `/` is used as the root
/// because its printed form is stable (no symlink resolution surprises).
async test "anchored_shell_starts_in_anchor_root" {
  let tools = ShellTools(
    anchor=Some(@devkit.WorkspaceAnchor::WorkspaceAnchor("/")),
  )
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("tc_pwd"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(Map::from_array([("cmd", Json::string("pwd"))])),
  }
  match tools.execute("bash", call) {
    Success(content~, ..) => assert_eq(content.trim(), "/")
    _ => fail("expected Success for pwd")
  }
}

///|
/// Each call is a fresh shell in the anchor root: `cd` inside one call works,
/// and relative paths resolve against the root (`/etc` exists on the native
/// test hosts).
async test "anchored_shell_resolves_relative_paths_from_root" {
  let tools = ShellTools(
    anchor=Some(@devkit.WorkspaceAnchor::WorkspaceAnchor("/")),
  )
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("tc_cd_pwd"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(
      Map::from_array([("cmd", Json::string("cd etc && pwd"))]),
    ),
  }
  match tools.execute("bash", call) {
    Success(content~, ..) => assert_eq(content.trim(), "/etc")
    _ => fail("expected Success for cd etc and pwd")
  }
}
