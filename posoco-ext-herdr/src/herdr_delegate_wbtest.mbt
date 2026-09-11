///|
/// Scripted channel: plays canned `(exit, stdout, stderr)` results in order
/// and records every argv it was handed, so the delegate flow runs without a
/// real herdr CLI.
priv struct FakeHerdrCli {
  results : Array[(Int, String, String)]
  mut index : Int
  received : Array[Array[String]]
}

///|
impl HerdrCli for FakeHerdrCli with fn run(
  self : FakeHerdrCli,
  argv : Array[String],
) -> (Int, String, String) raise @posoco.RuntimeError {
  self.received.push(argv)
  let result = self.results[self.index]
  self.index += 1
  result
}

///|
/// Fake channel that delays every run so concurrent delegates can be held
/// mid-flight; results cycle so four parallel flows share one script.
priv struct SlowHerdrCli {
  delay_ms : Int
  results : Array[(Int, String, String)]
  mut index : Int
  received : Array[Array[String]]
}

///|
impl HerdrCli for SlowHerdrCli with fn run(
  self : SlowHerdrCli,
  argv : Array[String],
) -> (Int, String, String) raise @posoco.RuntimeError {
  @async.sleep(self.delay_ms) catch {
    _ => ()
  }
  self.received.push(argv)
  let result = self.results[self.index]
  self.index = (self.index + 1) % self.results.length()
  result
}

///|
fn delegate_call(fields : Array[(String, Json)]) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("herdr-delegate-test"),
    name: @posoco.ToolName::unchecked("herdr_delegate"),
    arguments: Json::object(Map::from_array(fields)),
  }
}

///|
fn delegate_task_call(task : String) -> @posoco.ToolCall {
  delegate_call([("task", Json::string(task))])
}

///|
fn test_delegate() -> HerdrDelegate {
  HerdrDelegate::HerdrDelegate(
    pane="1-1",
    bin="herdr",
    headless_bin="cetas-headless",
    cwd="/tmp/ws",
  )
}

///|
fn split_ok() -> (Int, String, String) {
  (0, "{\"result\":{\"pane\":{\"pane_id\":\"1-3\"}}}", "")
}

///|
fn happy_script(session : String) -> Array[(Int, String, String)] {
  [
    split_ok(),
    (0, "", ""),
    (0, "", ""),
    (
      0,
      "session: \{session}\nheadless answer body\n[cetas-headless] turn 1 done\n",
      "",
    ),
    (0, "{\"result\":{\"type\":\"ok\"}}", ""),
  ]
}

///|
test "delegate tooldef shape" {
  let defs = HerdrDelegate::shared_list_tools()
  assert_eq(defs.length(), 1)
  let def = defs[0]
  assert_eq(def.name.value, "herdr_delegate")
  assert_eq(def.owner.value, "placeholder")
  assert_eq(def.provenance, Some("posoco_ext_herdr"))
  match def.policy {
    @posoco.ExecutionPolicy::Parallel => ()
    _ => fail("herdr_delegate must be Parallel so calls can ride tool waves")
  }
  match def.input_schema {
    Object(fields) =>
      match fields.get("required") {
        Some(Array(items)) => {
          assert_eq(items.length(), 1)
          assert_true(items[0] is String("task"))
        }
        _ => fail("schema must require exactly 'task'")
      }
    _ => fail("input_schema must be a JSON object")
  }
  assert_true(def.description.contains("parallel"))
  assert_true(def.description.contains("readonly"))
  assert_true(def.description.contains("MUST reuse"))
  assert_true(def.description.contains("even on failure and timeout"))
}

///|
test "delegate system prompt carries herdr context and is byte-stable" {
  let delegate = test_delegate()
  let first = delegate.system_prompt()
  assert_true(first != "")
  assert_true(first.contains("1-1"))
  assert_true(first.contains("depth-1"))
  assert_true(first.contains("herdr_delegate"))
  assert_true(first.contains("MUST reuse"))
  assert_eq(first, delegate.system_prompt())
}

///|
test "manifest lock: delegate contributes only itself, reporter stays tool-free" {
  let delegate = test_delegate()
  assert_eq(delegate.extension_id(), "posoco_ext_herdr_delegate")
  let m = delegate.manifest()
  assert_eq(m.id, "posoco_ext_herdr_delegate")
  assert_eq(m.tools.length(), 1)
  assert_eq(m.tools[0].list_tools()[0].name.value, "herdr_delegate")
  assert_eq(m.observers.length(), 0)
  assert_eq(m.sessions.length(), 0)
  assert_eq(m.commands.length(), 0)
  assert_eq(m.memory.length(), 0)
  assert_eq(m.prompt_contributors.length(), 1)
  let reporter : HerdrReporter = {
    pane: "1-1",
    bin: "herdr",
    spawn: (_bin, _args) => (),
  }
  assert_eq(reporter.manifest().tools.length(), 0)
  assert_eq(reporter.manifest().observers.length(), 1)
  assert_eq(reporter.manifest().prompt_contributors.length(), 0)
}

///|
async test "delegate happy path returns the answer with peer_pane and child_session footer" {
  let delegate = test_delegate()
  let fake : FakeHerdrCli = {
    results: happy_script("sess-7"),
    index: 0,
    received: [],
  }
  let outcome = delegate.execute_delegate_impl(
    fake,
    delegate_task_call("fix the bug"),
  )
  match outcome {
    @posoco.ToolOutcome::Success(content~, structured~) => {
      assert_true(content.contains("headless answer body"))
      assert_true(content.contains("peer_pane: 1-3"))
      assert_true(content.contains("child_session: sess-7"))
      assert_true(structured is None)
    }
    other => fail("expected Success, got " + other.to_string())
  }
  assert_eq(fake.received.length(), 5)
  assert_eq(fake.received[0], [
    "herdr", "pane", "split", "--pane", "1-1", "--direction", "right", "--cwd", "/tmp/ws",
    "--no-focus",
  ])
  assert_eq(fake.received[1], [
    "herdr", "pane", "run", "1-3", "cetas-headless --permission readonly -- 'fix the bug'",
  ])
  assert_eq(fake.received[2], [
    "herdr", "pane", "wait-output", "--match", "[cetas-headless] turn 1 done", "--timeout",
    "1800000", "1-3",
  ])
  assert_eq(fake.received[3], [
    "herdr", "pane", "read", "1-3", "--source", "recent-unwrapped",
  ])
  assert_eq(fake.received[4], ["herdr", "pane", "close", "1-3"])
}

///|
async test "delegate surfaces the headless failure line as ToolReportedError with peer_pane and child_session" {
  let delegate = test_delegate()
  let fake : FakeHerdrCli = {
    results: [
      split_ok(),
      (0, "", ""),
      (0, "", ""),
      (
        0, "session: s1\n[cetas-headless] turn failed: model exploded\n[cetas-headless] turn 1 done\n",
        "",
      ),
    ],
    index: 0,
    received: [],
  }
  let outcome = delegate.execute_delegate_impl(fake, delegate_task_call("x"))
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("turn failed: model exploded"))
      assert_true(content.contains("peer_pane: 1-3"))
      assert_true(content.contains("child_session: s1"))
    }
    other => fail("expected ToolReportedError, got " + other.to_string())
  }
  assert_eq(fake.received.length(), 4)
}

///|
async test "failure without a session line carries no child_session" {
  let delegate = test_delegate()
  let fake : FakeHerdrCli = {
    results: [
      split_ok(),
      (0, "", ""),
      (0, "", ""),
      (
        0, "[cetas-headless] turn failed: boom\n[cetas-headless] turn 1 done\n",
        "",
      ),
    ],
    index: 0,
    received: [],
  }
  match delegate.execute_delegate_impl(fake, delegate_task_call("x")) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("turn failed: boom"))
      assert_true(content.contains("peer_pane: 1-3"))
      assert_false(content.contains("child_session"))
    }
    other => fail("expected ToolReportedError, got " + other.to_string())
  }
  assert_eq(fake.received.length(), 4)
}

///|
async test "delegate wait timeout best-effort reads child_session into the error" {
  let delegate = test_delegate()
  let fake : FakeHerdrCli = {
    results: [
      split_ok(),
      (0, "", ""),
      (
        1, "", "{\"error\":{\"code\":\"timeout\",\"message\":\"no marker within timeout\"}}",
      ),
      (0, "session: sess-t\npartial output\n", ""),
    ],
    index: 0,
    received: [],
  }
  let outcome = delegate.execute_delegate_impl(
    fake,
    delegate_call([
      ("task", Json::string("x")),
      ("timeout_ms", Json::number(5000.0)),
    ]),
  )
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("timed out after 5000 ms"))
      assert_true(content.contains("peer_pane: 1-3"))
      assert_true(content.contains("left open"))
      assert_true(content.contains("may still be running"))
      assert_true(content.contains("child_session: sess-t"))
    }
    other =>
      fail("expected timeout ToolReportedError, got " + other.to_string())
  }
  assert_eq(fake.received.length(), 4)
  assert_eq(fake.received[2][6], "5000")
  assert_eq(fake.received[3], [
    "herdr", "pane", "read", "1-3", "--source", "recent-unwrapped",
  ])
}

///|
async test "timeout with an unreadable pane still errors without child_session" {
  let delegate = test_delegate()
  let fake : FakeHerdrCli = {
    results: [
      split_ok(),
      (0, "", ""),
      (
        1, "", "{\"error\":{\"code\":\"timeout\",\"message\":\"no marker within timeout\"}}",
      ),
      (1, "", "{\"error\":{\"code\":\"boom\"}}"),
    ],
    index: 0,
    received: [],
  }
  match
    delegate.execute_delegate_impl(
      fake,
      delegate_call([
        ("task", Json::string("x")),
        ("timeout_ms", Json::number(5000.0)),
      ]),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("timed out after 5000 ms"))
      assert_true(content.contains("peer_pane: 1-3"))
      assert_true(content.contains("left open"))
      assert_false(content.contains("child_session"))
    }
    other =>
      fail("expected timeout ToolReportedError, got " + other.to_string())
  }
  assert_eq(fake.received.length(), 4)
}

///|
async test "delegate split failure and unparseable split output are ToolReportedError" {
  let delegate = test_delegate()
  let failing : FakeHerdrCli = {
    results: [(1, "", "{\"error\":{\"code\":\"boom\"}}")],
    index: 0,
    received: [],
  }
  match delegate.execute_delegate_impl(failing, delegate_task_call("x")) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("pane split failed"))
      assert_true(content.contains("boom"))
    }
    other =>
      fail("expected split-failure ToolReportedError, got " + other.to_string())
  }
  let garbage : FakeHerdrCli = {
    results: [(0, "garbage", "")],
    index: 0,
    received: [],
  }
  match delegate.execute_delegate_impl(garbage, delegate_task_call("x")) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("no pane id"))
    other =>
      fail(
        "expected unparseable-split ToolReportedError, got " + other.to_string(),
      )
  }
}

///|
async test "delegate launch failure is a ToolReportedError" {
  let delegate = test_delegate()
  let fake : FakeHerdrCli = {
    results: [split_ok(), (2, "", "herdr: pane is dead")],
    index: 0,
    received: [],
  }
  match delegate.execute_delegate_impl(fake, delegate_task_call("x")) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("launching headless"))
      assert_true(content.contains("herdr: pane is dead"))
    }
    other =>
      fail(
        "expected launch-failure ToolReportedError, got " + other.to_string(),
      )
  }
}

///|
async test "delegate rejects multi-line task before any cli call" {
  let delegate = test_delegate()
  let fake : FakeHerdrCli = { results: [], index: 0, received: [], }
  let outcome = delegate.execute_delegate_impl(
    fake,
    delegate_task_call("line one\nline two"),
  )
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("task must be a single line"))
    other => fail("expected single-line rejection, got " + other.to_string())
  }
  assert_eq(fake.received.length(), 0)
  assert_eq(delegate.active, 0)
}

///|
async test "delegate validates task and permission before any cli call" {
  let delegate = test_delegate()
  let fake : FakeHerdrCli = { results: [], index: 0, received: [], }
  match delegate.execute_delegate_impl(fake, delegate_call([])) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("'task'"))
    other => fail("expected missing-task rejection, got " + other.to_string())
  }
  match
    delegate.execute_delegate_impl(
      fake,
      delegate_call([
        ("task", Json::string("x")),
        ("permission", Json::string("full")),
      ]),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("permission"))
      assert_true(content.contains("readonly"))
    }
    other => fail("expected permission rejection, got " + other.to_string())
  }
  match
    delegate.execute_delegate_impl(
      fake,
      delegate_call([
        ("task", Json::string("x")),
        ("direction", Json::string("up")),
      ]),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("'direction'"))
    other => fail("expected direction rejection, got " + other.to_string())
  }
  match
    delegate.execute_delegate_impl(
      fake,
      delegate_call([
        ("task", Json::string("x")),
        ("direction", Json::number(3.0)),
      ]),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("'direction' must be a string"))
    other => fail("expected direction-type rejection, got " + other.to_string())
  }
  match
    delegate.execute_delegate_impl(
      fake,
      delegate_call([
        ("task", Json::string("x")),
        ("close_pane", Json::string("yes")),
      ]),
    ) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("'close_pane' must be a boolean"))
    other => fail("expected close_pane rejection, got " + other.to_string())
  }
  assert_eq(fake.received.length(), 0)
}

///|
async test "execute raises UnknownTool for other names" {
  let delegate = test_delegate()
  let result = Ok(delegate.execute("herdr_report", delegate_task_call("x"))) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      assert_true(message.contains("unknown tool"))
    _ => fail("unknown name must raise UnknownTool")
  }
}

///|
async test "delegate concurrency cap refuses the fifth concurrent delegate" {
  let delegate = test_delegate()
  let slow : SlowHerdrCli = {
    delay_ms: 20,
    results: happy_script("s1"),
    index: 0,
    received: [],
  }
  @async.with_task_group(group => {
    for _ in 0..<4 {
      group.spawn_bg(() => {
        let outcome = Ok(
          delegate.execute_delegate_impl(slow, delegate_task_call("hold")),
        ) catch {
          e => Err(e)
        }
        ignore(outcome)
      })
    }
    @async.sleep(5)
    let fifth = Ok(
      delegate.execute_delegate_impl(slow, delegate_task_call("too many")),
    ) catch {
      e => Err(e)
    }
    match fifth {
      Ok(@posoco.ToolOutcome::ToolReportedError(content~, ..)) =>
        assert_true(content.contains("concurrency limit"))
      _ => fail("fifth concurrent delegate must hit the cap")
    }
  })
  assert_eq(delegate.active, 0)
}

///|
async test "close_pane=false keeps the pane and skips the close call" {
  let delegate = test_delegate()
  let fake : FakeHerdrCli = {
    results: happy_script("sess-8"),
    index: 0,
    received: [],
  }
  match
    delegate.execute_delegate_impl(
      fake,
      delegate_call([
        ("task", Json::string("x")),
        ("direction", Json::string("down")),
        ("close_pane", Json::boolean(false)),
      ]),
    ) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_false(content.contains("auto-close"))
    other => fail("expected Success, got " + other.to_string())
  }
  assert_eq(fake.received.length(), 4)
  assert_eq(fake.received[0], [
    "herdr", "pane", "split", "--pane", "1-1", "--direction", "down", "--cwd", "/tmp/ws",
    "--no-focus",
  ])
  for argv in fake.received {
    assert_false(argv.contains("close"))
  }
}

///|
async test "a failed pane close still returns Success with a note footer" {
  let delegate = test_delegate()
  let fake : FakeHerdrCli = {
    results: [
      split_ok(),
      (0, "", ""),
      (0, "", ""),
      (0, "session: s9\nanswer body\n[cetas-headless] turn 1 done\n", ""),
      (1, "", "{\"error\":{\"code\":\"boom\"}}"),
    ],
    index: 0,
    received: [],
  }
  match delegate.execute_delegate_impl(fake, delegate_task_call("x")) {
    @posoco.ToolOutcome::Success(content~, ..) => {
      assert_true(content.contains("answer body"))
      assert_true(
        content.contains("note: pane auto-close failed (pane still open)"),
      )
    }
    other =>
      fail("expected Success despite close failure, got " + other.to_string())
  }
  assert_eq(fake.received.length(), 5)
  assert_eq(fake.received[4], ["herdr", "pane", "close", "1-3"])
}

///|
test "delegate schema carries direction enum and close_pane boolean default" {
  let def = HerdrDelegate::shared_list_tools()[0]
  match def.input_schema {
    Object(fields) =>
      match fields.get("properties") {
        Some(Object(props)) => {
          match props.get("direction") {
            Some(Object(direction)) => {
              match direction.get("enum") {
                Some(Array(items)) => {
                  assert_eq(items.length(), 2)
                  assert_true(items[0] is String("right"))
                  assert_true(items[1] is String("down"))
                }
                _ => fail("direction enum must list right and down")
              }
              assert_true(direction.get("default") is Some(String("right")))
            }
            _ => fail("schema must define 'direction'")
          }
          match props.get("close_pane") {
            Some(Object(close)) => {
              assert_true(close.get("type") is Some(String("boolean")))
              assert_true(close.get("default") is Some(True))
            }
            _ => fail("schema must define 'close_pane'")
          }
        }
        _ => fail("schema must carry properties")
      }
    _ => fail("input_schema must be a JSON object")
  }
}
