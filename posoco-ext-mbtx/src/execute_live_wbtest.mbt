///|
/// Live smoke tests against the real MoonBit
/// toolchain. Every test skips itself (with a printed note) when
/// `~/.moon/bin/moon` is absent, so environments without the toolchain stay
/// green. The policy-deny test compiles a snippet importing
/// `moonbitlang/async`, which needs a one-time registry fetch (`moon
/// update`) on machines that never fetched it (design §8.4).

///|
async fn mbtx_live_toolchain_present() -> Bool {
  match @env.get_env_var("HOME") {
    Some(home) => @fs.can_execute("\{home}/.moon/bin/moon")
    None => false
  }
}

///|
fn mbtx_live_call(source : String) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("tc_mbtx_live"),
    name: @posoco.ToolName::unchecked("mbtx"),
    arguments: mbtx_args_obj([("source", Json::string(source))]),
  }
}

///|
fn mbtx_live_expect_reported_error(
  outcome : @posoco.ToolOutcome,
) -> String raise {
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, structured=None) => content
    other => fail("expected ToolReportedError, got: \{other}")
  }
}

///|
/// Count running `moonrun` processes (0 when pgrep is unavailable or
/// reports no match).
async fn mbtx_live_moonrun_count() -> Int {
  let (exit, output) = @process.collect_output_merged("pgrep", ["-x", "moonrun"]) catch {
    _ => return 0
  }
  if exit != 0 {
    return 0
  }
  let text = output.text() catch { _ => "" }
  let mut count = 0
  for line in text.split("\n") {
    if line.length() > 0 {
      count = count + 1
    }
  }
  count
}

///|
async test "live: hello snippet walks both stages to Success" {
  if !mbtx_live_toolchain_present() {
    println("mbtx live: no ~/.moon/bin/moon found; skipping live smoke")
    return
  }
  let tools = MbtxTools()
  let outcome = tools.execute(
    "mbtx",
    mbtx_live_call("fn main {\n  println(\"mbtx live ok\")\n}\n"),
  )
  let content = match outcome {
    @posoco.ToolOutcome::Success(content~, structured=None) => content
    other => fail("expected Success, got: \{other}")
  }
  assert_true(content.contains("mbtx live ok"))
}

///|
async test "live: write outside the tmpdir is denied by the policy" {
  if !mbtx_live_toolchain_present() {
    println("mbtx live: no ~/.moon/bin/moon found; skipping live smoke")
    return
  }
  let escape_path = "/tmp/posoco-mbtx-live-escape-should-not-exist.txt"
  let source = "import {\n  \"moonbitlang/async\",\n  \"moonbitlang/async/fs\"\n}\n\nasync fn main raise {\n  @fs.write_file(\"\{escape_path}\", \"nope\", create_mode=CreateOrTruncate)\n  println(\"wrote outside\")\n}\n"
  let tools = MbtxTools()
  let outcome = tools.execute("mbtx", mbtx_live_call(source))
  let content = mbtx_live_expect_reported_error(outcome)
  assert_true(content.contains("Sandbox policy blocked"))
  assert_true(content.contains(escape_path))
  // best-effort cleanup should a policy regression ever let the write through
  @fs.remove(escape_path) catch {
    _ => ()
  }
}

///|
/// Timeout termination, verified end to end: an infinite-loop snippet under
/// a 3s run budget must surface as a reported error AND leave no moonrun
/// process behind (with_timeout cancels the collection task, whose
/// cancel_handler SIGTERMs the child; moonrun dies on SIGTERM promptly).
async test "live: run timeout reports error and terminates moonrun" {
  if !mbtx_live_toolchain_present() {
    println("mbtx live: no ~/.moon/bin/moon found; skipping live smoke")
    return
  }
  let baseline = mbtx_live_moonrun_count()
  let tools = MbtxTools(run_timeout_ms=3000)
  let outcome = tools.execute(
    "mbtx",
    mbtx_live_call(
      "fn main {\n  let mut i = 0\n  while true {\n    i = i + 1\n  }\n}\n",
    ),
  )
  let content = mbtx_live_expect_reported_error(outcome)
  assert_true(content.contains("timed out"))
  // Give the SIGTERM a moment to land, then verify nothing lingers.
  @async.sleep(300) catch {
    _ => ()
  }
  let after = mbtx_live_moonrun_count()
  assert_true(after <= baseline)
}

///|
async test "live cmd: git --version runs as literal argv" {
  let probe = @process.collect_output_merged("git", ["--version"]) catch {
    _ => {
      println("cmd live: git not spawnable; skipping live smoke")
      return
    }
  }
  if probe.0 != 0 {
    println("cmd live: git not usable; skipping live smoke")
    return
  }
  let tools = MbtxTools()
  let outcome = tools.execute(
    "cmd",
    cmd_call(id="tc_cmd_live1", program="git", args=[Json::string("--version")]),
  )
  let content = match outcome {
    @posoco.ToolOutcome::Success(content~, structured=None) => content
    other => fail("expected Success, got: \{other}")
  }
  assert_true(content.contains("git version"))
}

///|
async test "live cmd: sh is rejected by the extension allowlist before spawn" {
  let tools = MbtxTools()
  let outcome = tools.execute(
    "cmd",
    cmd_call(id="tc_cmd_live2", program="sh", args=[
      Json::string("-c"),
      Json::string("echo pwned"),
    ]),
  )
  let content = mbtx_live_expect_reported_error(outcome)
  assert_true(content.contains("'sh' is not on the subprocess allowlist"))
  assert_true(content.contains("use the mbtx tool"))
}
