///|
/// js (bun) face of the execution edge: the extern
/// probe/env primitives, the Bun Runner (argv, merge, decode flag), the
/// extern-side budget (kill verified via pgrep), and the full live pipeline
/// (gated on MBTX_LIVE=1 AND a present ~/.moon/bin, like the native live
/// smokes). The runner tests run only tmpdir fixture binaries — no real
/// /bin/sh, /bin/echo, /bin/sleep, or host PATH probing by default.

///|
/// MBTX_LIVE=1 opts in to the live-toolchain js smokes; unset skips them.
fn js_wbtest_live_enabled() -> Bool {
  js_env_raw("MBTX_LIVE") == "1"
}

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
/// Write an executable fixture script (tmpdir-fake-binary pattern from
/// toolchain_wbtest.mbt). js_write_file_envelope cannot set modes, so the
/// exec bit is applied here; returns "" on success.
extern "js" fn js_wbtest_write_exec(path : String, body : String) -> String =
  #| (path, body) => {
  #|   const fs = require("node:fs");
  #|   try { fs.writeFileSync(path, body, { mode: 0o755 }); return ""; }
  #|   catch (e) { return String(e); }
  #| }

///|
/// Set (or, with "", delete) a variable in the real process environment, so
/// js_env_raw can be tested against an injected value instead of the host's.
extern "js" fn js_wbtest_set_env(name : String, value : String) -> Unit =
  #| (name, value) => { if (value === "") { delete process.env[name]; } else { process.env[name] = value; } }

///|
/// Fresh temp dir populated with executable `#!/bin/sh` fixture scripts.
fn js_wbtest_fixture_dir(scripts : Array[(String, String)]) -> String raise {
  let fields = match js_envelope_fields(js_mktmpdir_envelope("mbtx-js-test-")) {
    Some(fields) => fields
    None => fail("mbtx js tests: mkdtemp envelope decode failed")
  }
  if !js_fields_bool(fields, "ok") {
    fail("mbtx js tests: could not create the fixture dir")
  }
  let dir = js_fields_str(fields, "dir")
  for script in scripts {
    let (name, body) = script
    let error = js_wbtest_write_exec("\{dir}/\{name}", body)
    if error != "" {
      fail("mbtx js tests: could not write fixture \{name}: \{error}")
    }
  }
  dir
}

///|
/// Count processes whose full command line contains `pattern` (pgrep -f,
/// run through the Runner itself; 0 when pgrep is missing or reports no
/// match).
async fn js_wbtest_proc_count(pattern : String) -> Int {
  let (exit, output, _decoded) = mbtx_default_runner().run(
    "pgrep",
    ["-f", pattern],
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
  let dir = js_wbtest_fixture_dir([("probe-yes", "#!/bin/sh\nexit 0\n")])
  let plain = dir + "/probe-plain"
  let _ = js_write_file_envelope(plain, "not executable")
  assert_true(js_which_in("probe-yes", dir) != "")
  // Mere existence is not enough: the probe requires the exec bit.
  assert_true(js_which_in("probe-plain", dir) == "")
  assert_true(js_which_in("mbtx-no-such-binary-xyz", dir) == "")
}

///|
test "env raw reads the injected variable" {
  js_wbtest_set_env("MBTX_WBTEST_ENV_PROBE", "v1")
  assert_eq(js_env_raw("MBTX_WBTEST_ENV_PROBE"), "v1")
  js_wbtest_set_env("MBTX_WBTEST_ENV_PROBE", "")
  assert_eq(js_env_raw("MBTX_WBTEST_ENV_PROBE"), "")
}

///|
async test "runner spawns literal argv and merges output" {
  let dir = js_wbtest_fixture_dir([
    ("echo-fixture", "#!/bin/sh\necho out-part\necho err-part >&2\n"),
  ])
  let (exit, output, decoded) = mbtx_default_runner().run(
    "\{dir}/echo-fixture",
    [],
    None,
    5000,
  )
  assert_eq(exit, 0)
  // Merged stdout + stderr, joined by the one-newline separator.
  assert_eq(output, "out-part\n\nerr-part\n")
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
  // A tmpdir fixture busy-loop instead of /bin/sleep: its unique path makes
  // the pgrep -f liveness probe match only our own child, never the host's
  // sleep processes.
  let dir = js_wbtest_fixture_dir([
    ("budget-spinner", "#!/bin/sh\nwhile true; do :; done\n"),
  ])
  let script = "\{dir}/budget-spinner"
  let result = Ok(mbtx_default_runner().run(script, [], None, 300)) catch {
    e => Err(e)
  }
  match result {
    Err(e) =>
      if !(e is MbtxBudgetExpired::Expired) {
        fail("expected the budget-expiry marker")
      }
    Ok(_) => fail("expected the budget expiry to raise")
  }
  // The extern-side kill must not leave the child behind; poll briefly in
  // case the reaper lags the SIGTERM.
  let mut after = js_wbtest_proc_count(script)
  let mut attempts = 0
  while after > 0 && attempts < 40 {
    after = js_wbtest_proc_count(script)
    attempts += 1
  }
  assert_eq(after, 0)
}

///|
async test "js lists the mbtx and cmd tools" {
  let tools = MbtxTools()
  let defs = tools.list_tools()
  assert_eq(defs.length(), 2)
  assert_eq(defs[0].name.to_string(), "mbtx")
  assert_eq(defs[1].name.to_string(), "cmd")
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
  // MBTX_LIVE=1 gate: probes the real host toolchain.
  if !js_wbtest_live_enabled() {
    println("mbtx js live: set MBTX_LIVE=1 to run; skipping")
    return
  }
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
  // MBTX_LIVE=1 gate: runs the real toolchain.
  if !js_wbtest_live_enabled() {
    println("mbtx js live: set MBTX_LIVE=1 to run; skipping live smoke")
    return
  }
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
  // MBTX_LIVE=1 gate: runs the real toolchain and counts real processes.
  if !js_wbtest_live_enabled() {
    println("mbtx js live: set MBTX_LIVE=1 to run; skipping live smoke")
    return
  }
  if !js_wbtest_toolchain_present() {
    println("mbtx js live: no ~/.moon/bin toolchain found; skipping live smoke")
    return
  }
  let baseline = js_wbtest_proc_count("moonrun")
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
  let after = js_wbtest_proc_count("moonrun")
  assert_true(after <= baseline)
}
