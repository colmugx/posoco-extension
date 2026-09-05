///|
/// js_runner_wbtest.mbt — js (bun) face of the execution edge: the extern
/// probe/env primitives, the Bun Runner (argv, merge, decode flag), the
/// extern-side budget (kill verified via pgrep), and the full live pipeline
/// (self-skipping without ~/.moon/bin, like the native live smokes).

///|
fn js_wbtest_toolchain_present() -> Bool {
  let home = js_env_raw("HOME")
  home != "" &&
  js_which_in("moon", "\{home}/.moon/bin") != "" &&
  js_which_in("moonrun", "\{home}/.moon/bin") != ""
}

///|
fn js_wbtest_call(source : String) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("tc_js_wbtest"),
    name: @posoco.ToolName::unchecked("mbtx"),
    arguments: Json::object(Map::from_array([("source", Json::string(source))])),
  }
}

///|
/// Count processes named `name` via pgrep, run through the Runner itself
/// (0 when pgrep is missing or reports no match).
async fn js_wbtest_pgrep_count(name : String) -> Int {
  let (exit, output, _decoded) = mbtx_default_runner().run(
    "pgrep",
    ["-x", name],
    None,
    5000,
  ) catch {
    _ => return 0
  }
  if exit != 0 {
    return 0
  }
  let mut count = 0
  for line in output.split("\n") {
    if line.length() > 0 {
      count = count + 1
    }
  }
  count
}

///|
test "which probe resolves executables inside one directory" {
  assert_true(js_which_in("sh", "/bin") != "")
  assert_true(js_which_in("mbtx-no-such-binary-xyz", "/bin") == "")
}

///|
test "env raw reads PATH" {
  assert_true(js_env_raw("PATH") != "")
}

///|
async test "runner spawns literal argv and merges output" {
  let (exit, output, decoded) = mbtx_default_runner().run(
    "/bin/echo",
    ["hello", "world"],
    None,
    5000,
  )
  assert_eq(exit, 0)
  assert_eq(output, "hello world\n")
  assert_true(decoded)
}

///|
async test "runner spawn failure raises a generic error" {
  let result = Ok(
    mbtx_default_runner().run("/mbtx-no-such-binary-xyz", [], None, 5000),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(_) => ()
    Ok(_) => fail("expected the spawn failure to raise")
  }
}

///|
async test "runner budget expiry raises the budget marker and kills the child" {
  let before = js_wbtest_pgrep_count("sleep")
  let result = Ok(mbtx_default_runner().run("/bin/sleep", ["30"], None, 300)) catch {
    e => Err(e)
  }
  match result {
    Err(e) =>
      if !(e is MbtxBudgetExpired::Expired) {
        fail("expected the budget-expiry marker")
      }
    Ok(_) => fail("expected the budget expiry to raise")
  }
  // The extern-side kill must not leave the child behind.
  let _ = mbtx_default_runner().run("/bin/sleep", ["1"], None, 5000)
  let after = js_wbtest_pgrep_count("sleep")
  assert_true(after <= before)
}

///|
async test "js lists the mbtx tool" {
  let tools = MbtxTools()
  let defs = tools.list_tools()
  assert_eq(defs.length(), 1)
  assert_eq(defs[0].name.to_string(), "mbtx")
}

///|
async test "js raises the typed toolchain failure when nothing is usable" {
  let tools = MbtxTools()
  let result = Ok(
    tools.ensure_toolchain_from(
      path_env=Some(""),
      home_dir=Some("/nonexistent-mbtx-home"),
    ),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::InvocationFailed(msg)) => {
      assert_true(msg.contains("no MoonBit toolchain found"))
      assert_true(msg.contains("~/.moon/bin"))
    }
    _ => fail("expected InvocationFailed for a missing toolchain")
  }
}

///|
async test "js live: toolchain resolves through Bun.which" {
  if !js_wbtest_toolchain_present() {
    println("mbtx js live: no ~/.moon/bin toolchain found; skipping")
    return
  }
  let tools = MbtxTools()
  let tc = tools.ensure_toolchain()
  assert_true(tc.moon.has_suffix("/moon"))
  assert_true(tc.moonrun.has_suffix("/moonrun"))
}

///|
async test "js live: hello snippet walks both stages to Success" {
  if !js_wbtest_toolchain_present() {
    println("mbtx js live: no ~/.moon/bin toolchain found; skipping live smoke")
    return
  }
  let tools = MbtxTools()
  let outcome = tools.execute(
    "mbtx",
    js_wbtest_call("fn main {\n  println(\"mbtx js live ok\")\n}\n"),
  )
  let content = match outcome {
    @posoco.ToolOutcome::Success(content~, structured=None) => content
    other => fail("expected Success, got: \{other}")
  }
  assert_true(content.contains("mbtx js live ok"))
}

///|
async test "js live: run timeout reports error and terminates moonrun" {
  if !js_wbtest_toolchain_present() {
    println("mbtx js live: no ~/.moon/bin toolchain found; skipping live smoke")
    return
  }
  let baseline = js_wbtest_pgrep_count("moonrun")
  let tools = MbtxTools(run_timeout_ms=3000)
  let outcome = tools.execute(
    "mbtx",
    js_wbtest_call(
      "fn main {\n  let mut i = 0\n  while true {\n    i = i + 1\n  }\n}\n",
    ),
  )
  let content = match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, structured=None) => content
    other => fail("expected ToolReportedError, got: \{other}")
  }
  assert_true(content.contains("timed out"))
  // Give the SIGTERM a moment to land (a runner-driven wait), then verify
  // nothing lingers.
  let _ = mbtx_default_runner().run("/bin/sleep", ["1"], None, 5000)
  let after = js_wbtest_pgrep_count("moonrun")
  assert_true(after <= baseline)
}
