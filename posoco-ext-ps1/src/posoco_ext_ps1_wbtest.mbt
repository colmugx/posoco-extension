///|
/// posoco_ext_ps1_wbtest.mbt — Whitebox tests for PowerShellTools.
///
/// Pure tests run everywhere. Runtime fixtures probe the local PowerShell
/// first and skip silently when it is absent, so macOS/Linux dev machines and
/// CI without pwsh stay green.

///|
/// Test: PowerShellTools.list_tools
async test "list_tools_contains_powershell" {
  let tools = PowerShellTools(exe="pwsh")
  let tool_defs = tools.list_tools()
  let names = tool_defs.map(fn(t) { t.name.to_string() })
  assert_true(names.contains("powershell"))
  assert_eq(tool_defs.length(), 1)
}

///|
async test "list_tools_description_names_exe_and_syntax" {
  let pwsh_defs = PowerShellTools(exe="pwsh").list_tools()
  assert_true(pwsh_defs[0].description.contains("pwsh"))
  assert_true(pwsh_defs[0].description.contains("&&"))
  let ps51_defs = PowerShellTools(exe="powershell").list_tools()
  assert_true(ps51_defs[0].description.contains("NOT supported"))
}

///|
async test "list_tools_tool_defs_have_input_schema" {
  let tools = PowerShellTools(exe="pwsh")
  let tool_defs = tools.list_tools()
  for tool in tool_defs {
    assert_true(tool.input_schema is Json::Object(_))
  }
}

///|
async test "list_tools_have_provenance" {
  let tools = PowerShellTools(exe="pwsh")
  let tool_defs = tools.list_tools()
  for tool in tool_defs {
    match tool.provenance {
      Some(s) => assert_eq(s, "posoco_ext_ps1")
      None => fail("expected provenance to be set")
    }
  }
}

///|
/// Test: extract_command
test "extract_command_from_cmd_key" {
  let args = Json::object(
    Map::from_array([
      ("cmd", Json::string("Get-ChildItem")),
      ("dir", Json::string("C:\\tmp")),
    ]),
  )
  let cmd = extract_command(args)
  assert_eq(cmd, "Get-ChildItem")
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
    name: @posoco.ToolName::unchecked("powershell"),
    arguments: Json::object(Map::from_array([("cmd", Json::string(""))])),
  }
  let result = Ok(PowerShellTools(exe="pwsh").execute("powershell", call)) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.RuntimeError::InvocationFailed(message)) => {
      assert_true(message.contains("powershell"))
      assert_true(message.contains("stage=arguments"))
      assert_true(message.contains("empty_command"))
    }
    _ => fail("expected empty command to fail before process execution")
  }
}

///|
test "collect_output_failure_mapping_is_stage_only" {
  match ps1_collect_output_failure() {
    @posoco.RuntimeError::InvocationFailed(message) =>
      assert_eq(message, "powershell: process failed (stage=collect_output)")
    _ => fail("expected collect_output mapping to be InvocationFailed")
  }
}

///|
/// Test: windows_guidance (pure, runs on any platform)
test "windows_guidance_pwsh_flavor" {
  let text = windows_guidance("pwsh", "win32 10.0.26244")
  assert_true(text.contains("Environment: Windows (win32 10.0.26244)"))
  assert_true(text.contains("pipeline chains are supported"))
  assert_true(text.contains("$env:NAME"))
  assert_true(text.contains("NOT bash"))
  assert_true(text.contains(".NET objects"))
  assert_true(text.contains("Select-String"))
  assert_true(text.contains("awk '{print $1}'"))
  assert_true(text.contains("Get-ChildItem -Force"))
  assert_true(text.contains("Get-ChildItem -Recurse"))
  assert_true(text.contains("2>$null"))
  assert_true(text.contains("backslashes"))
  assert_true(text.contains("C:\\repo\\src\\main.rs"))
}

///|
test "windows_guidance_ps51_flavor" {
  let text = windows_guidance("powershell", "")
  assert_false(text.contains("Environment: Windows ("))
  assert_true(text.contains("NOT supported"))
  assert_true(text.contains("if ($?)"))
  assert_true(text.contains("NOT bash"))
}

///|
/// Test: SystemPromptContributor
async test "system_prompt_stable_and_platform_appropriate" {
  let tools = PowerShellTools(exe="pwsh")
  let first = tools.system_prompt()
  assert_eq(first, tools.system_prompt())
  if is_windows() {
    assert_true(first.contains("PowerShell"))
  } else {
    assert_eq(first, "")
  }
}

///|
/// Probe the local PowerShell (native target). False → skip runtime tests.
async fn probe_powershell(exe : String) -> Bool {
  let outcome = Ok(
    @process.collect_output_merged(exe, [
      "-NoProfile", "-NonInteractive", "-Command", "exit 0",
    ]),
  ) catch {
    _ => Err("probe_failed")
  }
  match outcome {
    Ok(_) => true
    Err(_) => false
  }
}

///|
/// Test: execute (runtime; requires a local pwsh)
async test "write_output_succeeds" {
  let tools = PowerShellTools(exe="pwsh")
  if probe_powershell(tools.exe) {
    let call : @posoco.ToolCall = {
      call_id: @posoco.CallId::unchecked("tc_echo"),
      name: @posoco.ToolName::unchecked("powershell"),
      arguments: Json::object(
        Map::from_array([("cmd", Json::string("Write-Output 'ps1_ok'"))]),
      ),
    }
    match tools.execute("powershell", call) {
      Success(content~, ..) => assert_eq(content.trim(), "ps1_ok")
      _ => fail("expected Success for Write-Output")
    }
  }
}

///|
async test "nonzero_exit_is_reported_error" {
  let tools = PowerShellTools(exe="pwsh")
  if probe_powershell(tools.exe) {
    let call : @posoco.ToolCall = {
      call_id: @posoco.CallId::unchecked("tc_exit3"),
      name: @posoco.ToolName::unchecked("powershell"),
      arguments: Json::object(
        Map::from_array([("cmd", Json::string("exit 3"))]),
      ),
    }
    match tools.execute("powershell", call) {
      ToolReportedError(..) => ()
      _ => fail("expected ToolReportedError for exit 3")
    }
  }
}

///|
/// An anchored session always starts in the anchor root. `/` is used as the
/// root because its printed form is stable.
async test "anchored_session_starts_in_anchor_root" {
  let tools = PowerShellTools(
    exe="pwsh",
    anchor=Some(@devkit.WorkspaceAnchor::WorkspaceAnchor("/")),
  )
  if probe_powershell(tools.exe) {
    let call : @posoco.ToolCall = {
      call_id: @posoco.CallId::unchecked("tc_loc"),
      name: @posoco.ToolName::unchecked("powershell"),
      arguments: Json::object(
        Map::from_array([("cmd", Json::string("(Get-Location).Path"))]),
      ),
    }
    match tools.execute("powershell", call) {
      Success(content~, ..) => assert_eq(content.trim(), "/")
      _ => fail("expected Success for (Get-Location).Path")
    }
  }
}

///|
async test "env_var_roundtrip_via_env_provider" {
  let tools = PowerShellTools(exe="pwsh")
  if probe_powershell(tools.exe) {
    let call : @posoco.ToolCall = {
      call_id: @posoco.CallId::unchecked("tc_env"),
      name: @posoco.ToolName::unchecked("powershell"),
      arguments: Json::object(
        Map::from_array([
          (
            "cmd",
            Json::string(
              "$env:CETAS_PS1_TEST = 'v1'; Write-Output $env:CETAS_PS1_TEST",
            ),
          ),
        ]),
      ),
    }
    match tools.execute("powershell", call) {
      Success(content~, ..) => assert_eq(content.trim(), "v1")
      _ => fail("expected Success for env var roundtrip")
    }
  }
}
