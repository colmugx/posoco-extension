///|
test "commands: /memory declares a positional status/flush action" {
  let ext = tool_ext()
  let defs = @posoco.CommandPort::commands(ext)
  inspect(defs.length(), content="1")
  let def = defs[0]
  inspect(def.id, content="memory")
  inspect(def.ctype is @posoco.CommandType::Action, content="true")
  inspect(def.params.length(), content="1")
  inspect(def.params[0].name, content="action")
  inspect(def.params[0].positional, content="true")
  inspect(def.shortcut is None, content="true")
  inspect(def.params[0].choices is Some(["status", "flush"]), content="true")
  // The manifest carries the command port view.
  inspect(@posoco.Extension::manifest(ext).commands.length(), content="1")
}

///|
async test "/memory status: connectivity, lanes, queue, and the passive-read gate" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "status",
        {
          exit: 0,
          stdout: "{\"mode\":\"local\",\"version\":\"1.2.3\"}",
          stderr: "",
        },
      ),
      ("wm", { exit: 0, stdout: "{\"exists\":false}", stderr: "" }),
    ]),
  )
  let ext = tool_ext(runner~)
  // One dirty lane, one queued write, one spent passive-read gate.
  let scope : @posoco.EventScope = {
    session_id: @posoco.SessionId::unchecked("s1"),
    run_id: @posoco.RunId::unchecked("r1"),
    turn_id: @posoco.TurnId::unchecked("t1"),
  }
  @posoco.Observer::on_event_at(
    ext,
    Some(scope),
    @posoco.TurnEvent::TurnStarted,
  )
  ignore(
    @posoco.PipelineHook::before_model(ext, [
      @posoco.tk_user_msg("hi"),
      assistant_msg("hello"),
    ]),
  )
  @posoco.Observer::on_event_at(
    ext,
    Some(scope),
    @posoco.TurnEvent::TurnCompleted,
  )
  ignore(
    @posoco.MemoryPort::store(ext, mem_entry(id="", content="queued note")),
  )
  ignore(@posoco.MemoryPort::search(ext, mem_query(query="anchor query")))
  let outcome = @posoco.CommandPort::invoke(
    ext,
    "memory",
    Json::string("status"),
  )
  guard outcome is @posoco.CommandOutcome::Success(feedback~, structured~, ..) else {
    fail("expected success")
  }
  assert_true(feedback.contains("nmem: connected"))
  assert_true(feedback.contains("posoco-s1"))
  assert_true(feedback.contains("acknowledged=0"))
  assert_true(feedback.contains("pending=true"))
  assert_true(feedback.contains("last_error=none"))
  assert_true(feedback.contains("memory queue: 1 pending write"))
  assert_true(feedback.contains("passive read: done"))
  guard structured is Some(payload) else { fail("expected structured") }
  inspect(
    json_field(payload, "nmem_connected") is Some(Json::True),
    content="true",
  )
  guard json_field(payload, "lanes") is Some(Json::Array(lanes)) else {
    fail("expected a lanes array")
  }
  inspect(lanes.length(), content="1")
  inspect(
    json_field(lanes[0], "thread_id") is Some(Json::String("posoco-s1")),
    content="true",
  )
  inspect(json_field(lanes[0], "pending") is Some(Json::True), content="true")
  guard json_field(payload, "queue_depth")
    is Some(Json::Number(queue_depth, ..)) else {
    fail("expected queue_depth")
  }
  inspect(queue_depth == 1.0, content="true")
  inspect(
    json_field(payload, "passive_read_done") is Some(Json::True),
    content="true",
  )
}

///|
async test "/memory status: an unspent gate reports pending" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([("status", { exit: 0, stdout: "{}", stderr: "" })]),
  )
  let ext = tool_ext(runner~)
  let outcome = @posoco.CommandPort::invoke(
    ext,
    "memory",
    Json::string("status"),
  )
  guard outcome is @posoco.CommandOutcome::Success(feedback~, structured~, ..) else {
    fail("expected success")
  }
  assert_true(feedback.contains("passive read: pending"))
  guard structured is Some(payload) else { fail("expected structured") }
  inspect(
    json_field(payload, "passive_read_done") is Some(Json::False),
    content="true",
  )
}

///|
async test "/memory status: an unreachable CLI reports it and still lists state" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("status", { exit: NMEM_CLI_ABORT_EXIT, stdout: "", stderr: "" }),
    ]),
  )
  let ext = tool_ext(runner~)
  let outcome = @posoco.CommandPort::invoke(
    ext,
    "memory",
    j("{\"action\":\"status\"}"),
  )
  guard outcome is @posoco.CommandOutcome::Success(feedback~, structured~, ..) else {
    fail("expected success")
  }
  assert_true(feedback.contains("nmem: unreachable"))
  assert_true(feedback.contains("nmem unavailable"))
  assert_true(feedback.contains("thread lanes: none yet"))
  assert_true(feedback.contains("memory queue: 0 pending write"))
  guard structured is Some(payload) else { fail("expected structured") }
  inspect(
    json_field(payload, "nmem_connected") is Some(Json::False),
    content="true",
  )
}

///|
async test "/memory flush drains staged lanes and the write queue" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:add", { exit: 0, stdout: "{\"id\":\"mem_7\"}", stderr: "" }),
    ]),
  )
  let ext = tool_ext(runner~)
  ignore(@posoco.MemoryPort::store(ext, mem_entry(id="", content="note")))
  let outcome = @posoco.CommandPort::invoke(
    ext,
    "memory",
    Json::string("flush"),
  )
  guard outcome is @posoco.CommandOutcome::Success(feedback~, structured~, ..) else {
    fail("expected success")
  }
  assert_true(feedback.contains("write queue empty"))
  inspect(ext.mem.queue.length(), content="0")
  guard structured is Some(payload) else { fail("expected structured") }
  inspect(
    json_field(payload, "lanes_attempted") is Some(Json::Number(0.0, ..)),
    content="true",
  )
  inspect(
    json_field(payload, "queue_remaining") is Some(Json::Number(0.0, ..)),
    content="true",
  )
  // A CLI failure keeps the write queued and says so.
  let fail_runner = FakeRunner::FakeRunner(
    replies=Map::from_array([("m:add", { exit: 1, stdout: "", stderr: "boom" })]),
  )
  let fail_ext = tool_ext(runner=fail_runner)
  ignore(
    @posoco.MemoryPort::store(fail_ext, mem_entry(id="", content="doomed")),
  )
  let failed = @posoco.CommandPort::invoke(
    fail_ext,
    "memory",
    Json::string("flush"),
  )
  guard failed is @posoco.CommandOutcome::Success(feedback=failed_feedback, ..) else {
    fail("expected success")
  }
  assert_true(failed_feedback.contains("1 write(s) still queued"))
  inspect(fail_ext.mem.queue.length(), content="1")
}

///|
async test "/memory with no action or an unknown action returns usage" {
  let ext = tool_ext()
  let bare = @posoco.CommandPort::invoke(ext, "memory", Json::null())
  guard bare is @posoco.CommandOutcome::Success(feedback=bare_feedback, ..) else {
    fail("expected success")
  }
  assert_true(bare_feedback.contains("/memory status"))
  assert_true(bare_feedback.contains("/memory flush"))
  assert_false(bare_feedback.contains("/memory refresh"))
  // An empty {action} object reads as no action.
  let empty_obj = @posoco.CommandPort::invoke(
    ext,
    "memory",
    j("{\"action\":\"\"}"),
  )
  guard empty_obj is @posoco.CommandOutcome::Success(feedback=obj_feedback, ..) else {
    fail("expected success")
  }
  inspect(obj_feedback == bare_feedback, content="true")
  let unknown = @posoco.CommandPort::invoke(
    ext,
    "memory",
    Json::string("vaporize"),
  )
  guard unknown is @posoco.CommandOutcome::Failure(reason~) else {
    fail("expected failure")
  }
  assert_true(reason.contains("unknown /memory action 'vaporize'"))
  assert_true(reason.contains("/memory status"))
  // The removed refresh subcommand is now an unknown action.
  let refresh = @posoco.CommandPort::invoke(
    ext,
    "memory",
    Json::string("refresh"),
  )
  guard refresh is @posoco.CommandOutcome::Failure(reason~) else {
    fail("expected failure")
  }
  assert_true(reason.contains("unknown /memory action 'refresh'"))
}

///|
async test "/memory invoke with a foreign id raises CommandError::NotFound" {
  let ext = tool_ext()
  try @posoco.CommandPort::invoke(ext, "memory_vaporize", Json::null()) catch {
    @posoco.CommandError::NotFound(_) => ()
    _ => fail("expected NotFound")
  } noraise {
    _ => fail("expected invoke to raise")
  }
}
