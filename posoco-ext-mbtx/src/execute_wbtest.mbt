///|
/// The two-stage pipeline against a scripted Runner:
/// argv/cwd/policy assertions, BUILD failure path rewriting, timeout
/// mapping, escalated argv, truncation and decode-failure handling. No
/// process is ever spawned; the only real fs access is the pipeline's temp
/// dir (written and cleaned within the call) which the fake reads at the
/// `--policy` path to capture the policy content mid-call.

///|
/// One recorded Runner invocation.
priv struct MbtxRunRecord {
  cmd : String
  args : Array[String]
  cwd : String?
}

///|
priv struct MbtxFakeRunner {
  // scripted (exit_code, output, decoded_ok) consumed by call index
  replies : Array[(Int, String, Bool)]
  calls : Array[MbtxRunRecord]
  // when set, run() sleeps this long before replying to the moonrun call
  // (drives the pipeline's RUN wall-clock timeout without delaying BUILD)
  mut moonrun_sleep_ms : Int?
  // when set, run() sleeps this long before replying to a cmd-tool call
  // (drives the cmd path's wall-clock timeout)
  mut cmd_sleep_ms : Int?
  // when true, the BUILD reply embeds the snippet path from that call's
  // argv (as a real compiler would), exercising the tmp-path rewrite
  mut echo_snippet_in_diagnostic : Bool
  // capture of the policy file passed via --policy during the RUN call
  mut policy_json : String?
}

///|
fn MbtxFakeRunner::new(replies : Array[(Int, String, Bool)]) -> MbtxFakeRunner {
  {
    replies,
    calls: [],
    moonrun_sleep_ms: None,
    cmd_sleep_ms: None,
    echo_snippet_in_diagnostic: false,
    policy_json: None,
  }
}

///|
impl Runner for MbtxFakeRunner with fn run(
  self : MbtxFakeRunner,
  cmd : String,
  args : Array[String],
  cwd : String?,
  _budget_ms : Int,
) -> (Int, String, Bool) {
  self.calls.push({ cmd, args, cwd, })
  if cmd.has_suffix("moonrun") {
    match self.moonrun_sleep_ms {
      Some(ms) => @async.sleep(ms) catch { _ => () }
      None => ()
    }
    // The policy file only exists while the call is in flight (the
    // pipeline removes the temp dir afterwards), so capture its content.
    for i in 0..<args.length() {
      if args[i] == "--policy" && i + 1 < args.length() {
        self.policy_json = Some(
          @fs.read_file(args[i + 1]).text() catch {
            _ => "<undecodable>"
          },
        )
      }
    }
  } else if !cmd.has_suffix("/moon") {
    // A cmd-tool invocation (the BUILD toolchain binary ends in "/moon").
    match self.cmd_sleep_ms {
      Some(ms) => @async.sleep(ms) catch { _ => () }
      None => ()
    }
  }
  let index = self.calls.length() - 1
  let (exit, output, decoded) = if index < self.replies.length() {
    self.replies[index]
  } else {
    (0, "", true)
  }
  if self.echo_snippet_in_diagnostic && index == 0 {
    let mut snippet = "<snippet-not-found>"
    for arg in args {
      if arg.has_suffix("/snippet.mbtx") {
        snippet = arg
      }
    }
    let diagnostic = "Error [4040]: at \{snippet}:1:5: variable `x` is not defined"
    let reply : (Int, String, Bool) = (exit, diagnostic, decoded)
    reply
  } else {
    let reply : (Int, String, Bool) = (exit, output, decoded)
    reply
  }
}

///|
/// Tools wired to the fake runner with the toolchain cache pre-seeded, so
/// execute never touches the host environment.
fn mbtx_fake_tools(
  runner~ : &Runner,
  anchor? : @devkit.WorkspaceAnchor? = None,
  run_timeout_ms? : Int = 120_000,
  escalation? : Bool = false,
) -> MbtxTools {
  let tools = MbtxTools::with_runner(
    runner~,
    anchor~,
    run_timeout_ms~,
    escalation~,
  )
  tools.cache_resolved("/fake-moon-bin")
  tools
}

///|
fn mbtx_outcome_content(outcome : @posoco.ToolOutcome) -> String raise {
  match outcome {
    @posoco.ToolOutcome::Success(content~, structured=None) => content
    @posoco.ToolOutcome::ToolReportedError(content~, structured=None) => content
    other => fail("expected Success/ToolReportedError, got: \{other}")
  }
}

///|
let mbtx_build_ok_output : String = "{\"artifacts_path\":[\"/fake/build/out.wasm\"]}"

///|
async test "pipeline runs build then run with expected argv cwd and policy" {
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor("/ws")
  let runner = MbtxFakeRunner::new([
    (0, mbtx_build_ok_output, true),
    (0, "script done\n", true),
  ])
  let tools = mbtx_fake_tools(runner~, anchor=Some(anchor))
  let outcome = tools.execute("mbtx", {
    call_id: @posoco.CallId::unchecked("tc1"),
    name: @posoco.ToolName::unchecked("mbtx"),
    arguments: mbtx_args_obj([
      ("source", Json::string("fn main { println(1) }")),
    ]),
  })
  assert_eq(mbtx_outcome_content(outcome), "script done\n")
  assert_eq(runner.calls.length(), 2)
  // BUILD call: absolute snippet, compile-only, per-call build dir.
  let build = runner.calls[0]
  assert_eq(build.cmd, "/fake-moon-bin/moon")
  assert_eq(build.args.length(), 7)
  assert_eq(build.args[0], "run")
  let snippet_arg = build.args[1]
  assert_true(snippet_arg.has_suffix("/snippet.mbtx"))
  assert_eq(build.args[2], "--build-only")
  assert_eq(build.args[3], "--target")
  assert_eq(build.args[4], "wasm")
  assert_eq(build.args[5], "--target-dir")
  assert_true(build.args[6].has_suffix("/build"))
  assert_eq(build.cwd, None)
  // RUN call: artifact under moonrun, policy path inside the same tmpdir,
  // cwd pinned to the anchor root.
  let run = runner.calls[1]
  assert_eq(run.cmd, "/fake-moon-bin/moonrun")
  assert_eq(run.args.length(), 3)
  assert_eq(run.args[0], "/fake/build/out.wasm")
  assert_eq(run.args[1], "--policy")
  assert_true(run.args[2].has_suffix("/policy.json"))
  assert_eq(run.cwd, Some("/ws"))
  // policy file content: write confined to exactly this call's tmpdir
  // (absolute, derived from the BUILD argv to stay hermetic).
  let json = match runner.policy_json {
    Some(text) => text
    None => fail("the fake never saw a --policy file to capture")
  }
  let snippet_suffix = "/snippet.mbtx"
  let tmpdir = snippet_arg[0:snippet_arg.length() - snippet_suffix.length()].to_owned()
  assert_true(json.contains("\"write\":[\"\{tmpdir}\"]"))
}

///|
async test "build failure rewrites tmp paths and reports a business error" {
  let runner = MbtxFakeRunner::new([(1, "", true)])
  runner.echo_snippet_in_diagnostic = true
  let tools = mbtx_fake_tools(runner~)
  let outcome = tools.execute("mbtx", {
    call_id: @posoco.CallId::unchecked("tc2"),
    name: @posoco.ToolName::unchecked("mbtx"),
    arguments: mbtx_args_obj([
      ("source", Json::string("fn main { undefined_name }")),
    ]),
  })
  let content = mbtx_outcome_content(outcome)
  assert_true(content.contains("mbtx: BUILD failed (exit 1)"))
  assert_true(content.contains("snippet.mbtx:1:5"))
  let snippet_arg = runner.calls[0].args[1]
  let snippet_suffix = "/snippet.mbtx"
  let tmpdir = snippet_arg[0:snippet_arg.length() - snippet_suffix.length()].to_owned()
  assert_false(content.contains(tmpdir))
  // no RUN attempt after a failed BUILD
  assert_eq(runner.calls.length(), 1)
}

///|
async test "run failure and missing anchor surface raw output as error" {
  let runner = MbtxFakeRunner::new([
    (0, mbtx_build_ok_output, true),
    (3, "script exploded", true),
  ])
  let tools = mbtx_fake_tools(runner~)
  let outcome = tools.execute("mbtx", {
    call_id: @posoco.CallId::unchecked("tc3"),
    name: @posoco.ToolName::unchecked("mbtx"),
    arguments: mbtx_args_obj([("source", Json::string("s"))]),
  })
  assert_eq(mbtx_outcome_content(outcome), "script exploded")
  assert_eq(runner.calls[1].cwd, None)
}

///|
async test "run timeout maps to a reported error within the budget" {
  let runner = MbtxFakeRunner::new([
    (0, mbtx_build_ok_output, true),
    (0, "never arrives", true),
  ])
  runner.moonrun_sleep_ms = Some(5000)
  let tools = mbtx_fake_tools(runner~, run_timeout_ms=300)
  let outcome = tools.execute("mbtx", {
    call_id: @posoco.CallId::unchecked("tc4"),
    name: @posoco.ToolName::unchecked("mbtx"),
    arguments: mbtx_args_obj([("source", Json::string("s"))]),
  })
  let content = mbtx_outcome_content(outcome)
  assert_true(content.contains("mbtx: RUN timed out after 300ms"))
}

///|
async test "escalated run drops the policy argument" {
  let runner = MbtxFakeRunner::new([
    (0, mbtx_build_ok_output, true),
    (0, "escalated ok", true),
  ])
  let tools = mbtx_fake_tools(runner~, escalation=true)
  let outcome = tools.execute("mbtx", {
    call_id: @posoco.CallId::unchecked("tc5"),
    name: @posoco.ToolName::unchecked("mbtx"),
    arguments: mbtx_args_obj([
      ("source", Json::string("s")),
      ("escalated", Json::boolean(true)),
    ]),
  })
  assert_eq(mbtx_outcome_content(outcome), "escalated ok")
  assert_eq(runner.calls[1].args, ["/fake/build/out.wasm"])
}

///|
async test "oversized run output is truncated keeping the tail" {
  let big = "x".repeat(70_000) + "TAIL-MARKER"
  let runner = MbtxFakeRunner::new([
    (0, mbtx_build_ok_output, true),
    (0, big, true),
  ])
  let tools = mbtx_fake_tools(runner~)
  let outcome = tools.execute("mbtx", {
    call_id: @posoco.CallId::unchecked("tc6"),
    name: @posoco.ToolName::unchecked("mbtx"),
    arguments: mbtx_args_obj([("source", Json::string("s"))]),
  })
  let content = mbtx_outcome_content(outcome)
  assert_true(content.contains("output truncated"))
  assert_true(content.has_suffix("TAIL-MARKER"))
  assert_true(content.length() < 66_000)
}

///|
async test "build success without artifacts_path is a reported error" {
  let runner = MbtxFakeRunner::new([(0, "no json here", true)])
  let tools = mbtx_fake_tools(runner~)
  let outcome = tools.execute("mbtx", {
    call_id: @posoco.CallId::unchecked("tc7"),
    name: @posoco.ToolName::unchecked("mbtx"),
    arguments: mbtx_args_obj([("source", Json::string("s"))]),
  })
  let content = mbtx_outcome_content(outcome)
  assert_true(content.contains("artifacts_path"))
  assert_eq(runner.calls.length(), 1)
}

///|
async test "undecodable run output is reported as invalid_utf8" {
  let runner = MbtxFakeRunner::new([
    (0, mbtx_build_ok_output, true),
    (0, "", false),
  ])
  let tools = mbtx_fake_tools(runner~)
  let outcome = tools.execute("mbtx", {
    call_id: @posoco.CallId::unchecked("tc8"),
    name: @posoco.ToolName::unchecked("mbtx"),
    arguments: mbtx_args_obj([("source", Json::string("s"))]),
  })
  let content = mbtx_outcome_content(outcome)
  assert_true(content.contains("invalid_utf8"))
  assert_true(content.contains("exit_code=0"))
}

///|
fn cmd_call(
  id~ : String,
  program~ : String,
  args? : Array[Json] = [],
) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked(id),
    name: @posoco.ToolName::unchecked("cmd"),
    arguments: mbtx_args_obj([
      ("program", Json::string(program)),
      ("args", Json::array(args)),
    ]),
  }
}

///|
async test "cmd runs an allowlisted program with literal argv and anchor cwd" {
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor("/ws")
  let runner = MbtxFakeRunner::new([(0, "git version 2.46\n", true)])
  let tools = mbtx_fake_tools(runner~, anchor=Some(anchor))
  let outcome = tools.execute(
    "cmd",
    cmd_call(id="tc_cmd1", program="git", args=[Json::string("--version")]),
  )
  assert_eq(mbtx_outcome_content(outcome), "git version 2.46\n")
  assert_eq(runner.calls.length(), 1)
  assert_eq(runner.calls[0].cmd, "git")
  assert_eq(runner.calls[0].args, ["--version"])
  assert_eq(runner.calls[0].cwd, Some("/ws"))
}

///|
async test "cmd without anchor inherits cwd and defaults args to empty" {
  let runner = MbtxFakeRunner::new([(0, "ok", true), (0, "ok", true)])
  let tools = mbtx_fake_tools(runner~)
  let outcome = tools.execute(
    "cmd",
    cmd_call(id="tc_cmd2", program="rg", args=[Json::string("pattern")]),
  )
  assert_eq(mbtx_outcome_content(outcome), "ok")
  assert_eq(runner.calls[0].cwd, None)
  let outcome = tools.execute("cmd", {
    call_id: @posoco.CallId::unchecked("tc_cmd3"),
    name: @posoco.ToolName::unchecked("cmd"),
    arguments: mbtx_args_obj([("program", Json::string("rg"))]),
  })
  assert_eq(mbtx_outcome_content(outcome), "ok")
  assert_eq(runner.calls[1].args, [])
}

///|
async test "cmd rejects a non-allowlisted program before any spawn" {
  let runner = MbtxFakeRunner::new([])
  let tools = mbtx_fake_tools(runner~)
  let outcome = tools.execute(
    "cmd",
    cmd_call(id="tc_cmd4", program="sh", args=[
      Json::string("-c"),
      Json::string("ls"),
    ]),
  )
  let content = mbtx_outcome_content(outcome)
  assert_true(content.contains("'sh' is not on the subprocess allowlist"))
  assert_true(content.contains("- moon — any arguments"))
  assert_true(content.contains("- git — any arguments"))
  assert_true(content.contains("use the mbtx tool"))
  assert_eq(runner.calls.length(), 0)
}

///|
async test "cmd enforces the args_prefix rule extension-side" {
  let runner = MbtxFakeRunner::new([(0, "pushed", true)])
  let tools = MbtxTools::with_runner(runner~, allowlist_without=["git"], allowlist_extra=[
    { program: "git", args_prefix: ["push"], },
  ])
  tools.cache_resolved("/fake-moon-bin")
  let outcome = tools.execute(
    "cmd",
    cmd_call(id="tc_cmd5", program="git", args=[
      Json::string("push"),
      Json::string("origin"),
    ]),
  )
  assert_eq(mbtx_outcome_content(outcome), "pushed")
  assert_eq(runner.calls[0].args, ["push", "origin"])
  let outcome = tools.execute(
    "cmd",
    cmd_call(id="tc_cmd6", program="git", args=[Json::string("log")]),
  )
  assert_true(
    mbtx_outcome_content(outcome).contains(
      "'git' is not on the subprocess allowlist",
    ),
  )
  assert_eq(runner.calls.length(), 1)
}

///|
async test "cmd non-zero exit is a reported error with raw output" {
  let runner = MbtxFakeRunner::new([(3, "boom\n", true)])
  let tools = mbtx_fake_tools(runner~)
  let outcome = tools.execute(
    "cmd",
    cmd_call(id="tc_cmd7", program="diff", args=[
      Json::string("a"),
      Json::string("b"),
    ]),
  )
  assert_eq(mbtx_outcome_content(outcome), "boom\n")
}

///|
async test "cmd timeout maps to a reported error within the budget" {
  let runner = MbtxFakeRunner::new([(0, "never arrives", true)])
  runner.cmd_sleep_ms = Some(5000)
  let tools = mbtx_fake_tools(runner~, run_timeout_ms=300)
  let outcome = tools.execute(
    "cmd",
    cmd_call(id="tc_cmd8", program="moon", args=[Json::string("test")]),
  )
  assert_true(
    mbtx_outcome_content(outcome).contains("cmd: 'moon' timed out after 300ms"),
  )
}

///|
async test "cmd oversized output is truncated keeping the tail" {
  let big = "x".repeat(70_000) + "TAIL-MARKER"
  let runner = MbtxFakeRunner::new([(0, big, true)])
  let tools = mbtx_fake_tools(runner~)
  let outcome = tools.execute(
    "cmd",
    cmd_call(id="tc_cmd9", program="rg", args=[Json::string("x")]),
  )
  let content = mbtx_outcome_content(outcome)
  assert_true(content.contains("output truncated"))
  assert_true(content.has_suffix("TAIL-MARKER"))
}

///|
async test "cmd undecodable output is reported as invalid_utf8" {
  let runner = MbtxFakeRunner::new([(0, "", false)])
  let tools = mbtx_fake_tools(runner~)
  let outcome = tools.execute("cmd", cmd_call(id="tc_cmd10", program="rg"))
  let content = mbtx_outcome_content(outcome)
  assert_true(content.contains("invalid_utf8"))
  assert_true(content.contains("exit_code=0"))
}

///|
async test "cmd decode errors are typed and surface before execution" {
  let runner = MbtxFakeRunner::new([])
  let tools = mbtx_fake_tools(runner~)
  let result = Ok(tools.execute("cmd", cmd_call(id="tc_cmd11", program=""))) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("non-empty"))
    _ => fail("expected empty program rejection")
  }
  let result = Ok(
    tools.execute("cmd", {
      call_id: @posoco.CallId::unchecked("tc_cmd12"),
      name: @posoco.ToolName::unchecked("cmd"),
      arguments: mbtx_args_obj([("args", Json::array([]))]),
    }),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("missing 'program'"))
    _ => fail("expected missing program rejection")
  }
  let result = Ok(
    tools.execute("cmd", {
      call_id: @posoco.CallId::unchecked("tc_cmd13"),
      name: @posoco.ToolName::unchecked("cmd"),
      arguments: mbtx_args_obj([
        ("program", Json::string("git")),
        ("args", Json::array([Json::number(1.0)])),
      ]),
    }),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("'args' must be an array of strings"))
    _ => fail("expected non-string args item rejection")
  }
  let result = Ok(
    tools.execute("cmd", {
      call_id: @posoco.CallId::unchecked("tc_cmd14"),
      name: @posoco.ToolName::unchecked("cmd"),
      arguments: mbtx_args_obj([
        ("program", Json::string("git")),
        ("args", Json::string("--version")),
      ]),
    }),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("'args' must be an array of strings"))
    _ => fail("expected non-array args rejection")
  }
  assert_eq(runner.calls.length(), 0)
}
