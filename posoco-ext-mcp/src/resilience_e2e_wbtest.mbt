///|
/// Native end-to-end resilience tests: real node subprocesses running
/// test_fixtures/echo_server.mjs (MCP_FIXTURE_RESILIENCE=1 gate) behind a
/// tmpdir mcp.json, driven through the same public path a host uses —
/// discover → attach → activate → &@posoco.ToolProvider list/execute.
///
/// The surrounding task group must outlive every connection: stdio children
/// are spawned on it and get terminated when it closes, so no test can leave
/// an orphan node process behind.

///|
/// Observation box for the cancellation scenario; shared by reference with
/// the spawned task. Cancellation identity is read INSIDE the raising task.
priv struct CancelProbe {
  mut settled : Bool
  mut raised : Bool
  mut message : String
  mut cancelled_flag : Bool
}

///|
/// Resolve the node executable (PATH scan, overridable via
/// POSOCO_MCP_E2E_NODE). None → callers skip their scenario.
async fn e2e_find_node() -> String? {
  match @env.get_env_var("POSOCO_MCP_E2E_NODE") {
    Some(path) => return Some(path)
    None => ()
  }
  let path_var = match @env.get_env_var("PATH") {
    Some(value) => value
    None => return None
  }
  for dir in path_var.split(":") {
    if dir.is_empty() {
      continue
    }
    let candidate = dir.to_owned() + "/node"
    if @fs.exists(candidate) && @fs.can_execute(candidate) {
      return Some(candidate)
    }
  }
  None
}

///|
/// Write a tmpdir mcp.json whose project entry runs the fixture server with
/// `extra_entry` (raw JSON fields appended to the echo server entry, e.g.
/// "timeout_ms":300) and the given fixture env; returns the discovery cwd.
async fn e2e_fixture_cwd(
  node : String,
  extra_entry : String,
  fixture_env : Array[(String, String)],
) -> String {
  let root = @fs.tmpdir(prefix="posoco-mcp-e2e")
  let script = @fs.realpath("test_fixtures/echo_server.mjs") catch {
    _ => "test_fixtures/echo_server.mjs"
  }
  let env_pairs = fixture_env
    .map(fn(pair) { "\"\{pair.0}\":\"\{pair.1}\"" })
    .join(",")
  let content = "{\"mcpServers\":{\"echo\":{\"command\":\"\{node}\",\"args\":[\"\{script}\"],\"env\":{\{env_pairs}}\{extra_entry}}}}"
  @fs.write_file(
    root + "/.mcp.json",
    content,
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o644,
  ) catch {
    _ => fail("e2e setup: could not write mcp.json")
  }
  root
}

///|
/// discover → attach → activate on the caller's long-lived task group.
/// Node availability is checked by the caller; an activation failure here is
/// a real error, not a skip.
async fn e2e_activate_bridge(
  group : @async.TaskGroup[Unit],
  node : String,
  extra_entry : String,
  fixture_env : Array[(String, String)],
) -> MCPToolBridge {
  let cwd = e2e_fixture_cwd(node, extra_entry, fixture_env)
  let bridge = match MCPToolBridge::discover(cwd~, home=cwd + "/nohome") {
    Ok(bridge) => bridge
    Err(message) => fail("discover failed: " + message)
  }
  bridge.attach(group)
  let failures = bridge.activate()
  if failures.length() > 0 {
    fail("activate failed: " + failures[0].1)
  }
  bridge
}

///|
fn e2e_call(
  name : String,
  arguments : Array[(String, Json)],
) -> @posoco.ToolCall {
  {
    call_id: @kernel.CallId::unchecked("call_e2e"),
    name: @posoco.ToolName::unchecked(name),
    arguments: Json::object(Map::from_array(arguments)),
  }
}

///|
/// One tool call through the ToolProvider boundary; Err carries the
/// RuntimeError rendering (e.g. "RuntimeError::InvocationFailed(...)").
async fn e2e_execute(
  bridge : MCPToolBridge,
  tool : String,
  arguments : Array[(String, Json)],
) -> Result[String, String] {
  let call = e2e_call(tool, arguments)
  let outcome : Result[@posoco.ToolOutcome, @posoco.RuntimeError] = Ok(
    @posoco.ToolProvider::execute(bridge, tool, call),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(Success(content~, ..)) => Ok(content)
    Ok(ToolReportedError(content~, ..)) => Err("ToolReportedError: \{content}")
    Ok(_) => Err("unexpected MCP tool outcome")
    Err(error) => Err(error.to_string())
  }
}

///|
async fn e2e_read_text(path : String) -> String? {
  let data = @fs.read_file(path) catch { _ => return None }
  let text = data.text() catch { _ => return None }
  Some(text)
}

///|
/// Contract 1+2: timeout_ms bounds one tools/call with a distinguishable
/// error, and the stale-response safety default force-reconnects the
/// connection so the very next call succeeds.
async fn e2e_timeout_scenario(node : String) -> Unit {
  @async.with_task_group(group => {
    let bridge = e2e_activate_bridge(group, node, ",\"timeout_ms\":300", [
      ("MCP_FIXTURE_RESILIENCE", "1"),
    ])
    // The RESILIENCE gate reached the spawned server.
    let names : Array[String] = []
    for tool in @posoco.ToolProvider::list_tools(bridge) {
      names.push(tool.name.to_string())
    }
    assert_true(names.contains("echo__sleep"))
    assert_true(names.contains("echo__exit"))
    let t0 = @async.now()
    let outcome = e2e_execute(bridge, "echo__sleep", [
      ("ms", Json::number(5000)),
    ])
    let elapsed = @async.now() - t0
    let message = match outcome {
      Err(message) => message
      Ok(content) => fail("sleep call should have timed out, got: " + content)
    }
    assert_true(message.contains("stage=timeout"))
    assert_true(message.contains("timeout_ms=300"))
    // A real reply needs 5s; a fired 300ms deadline must surface far earlier
    // even on a loaded machine.
    assert_true(elapsed < 2_000L)
    // Stale-response safety: the timed-out connection is force-reconnected
    // before its next use (not charged to max_reconnects), so this succeeds.
    match e2e_execute(bridge, "echo__echo", []) {
      Ok(content) => assert_true(content.has_prefix("echo:"))
      Err(message) => fail("expected recovery after timeout, got: " + message)
    }
    bridge.close()
  })
}

///|
async test "e2e timeout bounds the call and stale safety recovers" {
  match e2e_find_node() {
    Some(node) => e2e_timeout_scenario(node)
    // skip: node is unavailable in this environment
    None => assert_true(true)
  }
}

///|
/// Contract 3: server exit (connection-level EOF) triggers one reactive
/// reconnect + retry under the default max_reconnects=1, and the call
/// succeeds on the fresh connection.
async fn e2e_exit_reconnect_scenario(node : String) -> Unit {
  @async.with_task_group(group => {
    let bridge = e2e_activate_bridge(group, node, "", [
      ("MCP_FIXTURE_RESILIENCE", "1"),
    ])
    let revision_after_activate = bridge.catalog_revision
    match e2e_execute(bridge, "echo__echo", []) {
      Ok(_) => ()
      Err(message) => fail("first echo failed: " + message)
    }
    match e2e_execute(bridge, "echo__exit", []) {
      Ok(content) => assert_eq(content, "exiting")
      Err(message) => fail("exit call failed: " + message)
    }
    // The fixture exits 50ms after its reply; wait past that so the next call
    // deterministically hits a dead connection instead of racing the exit.
    @async.sleep(600)
    match e2e_execute(bridge, "echo__echo", []) {
      Ok(content) => assert_true(content.has_prefix("echo:"))
      Err(message) =>
        fail("expected reactive reconnect to recover, got: " + message)
    }
    assert_eq(bridge.catalog_revision, revision_after_activate)
    bridge.close()
  })
}

///|
async test "e2e server exit recovers through reactive reconnect" {
  match e2e_find_node() {
    Some(node) => e2e_exit_reconnect_scenario(node)
    None => assert_true(true)
  }
}

///|
/// Contract 4: with "max_reconnects": 0 (exercising the M4 json parse through
/// the full discover chain) a connection-level failure fails fast with no
/// retry and no recovery.
async fn e2e_no_reconnect_scenario(node : String) -> Unit {
  @async.with_task_group(group => {
    let bridge = e2e_activate_bridge(group, node, ",\"max_reconnects\":0", [
      ("MCP_FIXTURE_RESILIENCE", "1"),
    ])
    let revision_before = bridge.catalog_revision
    match e2e_execute(bridge, "echo__echo", []) {
      Ok(_) => ()
      Err(message) => fail("first echo failed: " + message)
    }
    match e2e_execute(bridge, "echo__exit", []) {
      Ok(content) => assert_eq(content, "exiting")
      Err(message) => fail("exit call failed: " + message)
    }
    @async.sleep(600)
    let outcome = e2e_execute(bridge, "echo__echo", [])
    let message = match outcome {
      Err(message) => message
      Ok(content) =>
        fail("retry is disabled, echo should not recover, got: " + content)
    }
    assert_true(message.contains("stage=transport"))
    assert_eq(bridge.catalog_revision, revision_before)
    bridge.close()
  })
}

///|
async test "e2e max_reconnects zero keeps the failure unrecovered" {
  match e2e_find_node() {
    Some(node) => e2e_no_reconnect_scenario(node)
    None => assert_true(true)
  }
}

///|
/// Contract 5: a cancelled MCP execute keeps its cancellation identity at the
/// ToolProvider boundary (dedicated marker or the sticky cancel flag), never
/// hangs, and leaves the connection usable for the next call.
async fn e2e_cancel_scenario(node : String, notification_log : String) -> Unit {
  @async.with_task_group(group => {
    let env : Array[(String, String)] = [("MCP_FIXTURE_RESILIENCE", "1")]
    if notification_log != "" {
      env.push(("MCP_FIXTURE_NOTIFICATION_LOG", notification_log))
    }
    let bridge = e2e_activate_bridge(group, node, "", env)
    let probe = CancelProbe::{
      settled: false,
      raised: false,
      message: "",
      cancelled_flag: false,
    }
    let task = group.spawn(() => {
      match e2e_execute(bridge, "echo__sleep", [("ms", Json::number(8000))]) {
        Ok(content) => {
          probe.settled = true
          probe.message = "unexpected success: \{content}"
        }
        Err(message) => {
          probe.settled = true
          probe.raised = true
          probe.message = message
          // Read inside the raising task: the sticky cancel flag is the
          // cancellation identity that survives the trait boundary.
          probe.cancelled_flag = @async.is_being_cancelled()
        }
      }
    })
    @async.sleep(200)
    task.cancel()
    let mut waited = 0
    while !probe.settled && waited < 5_000 {
      @async.sleep(25)
      waited += 25
    }
    assert_true(probe.settled)
    assert_true(probe.raised)
    let marker = probe.message.contains("MCP tool call cancelled")
    assert_true(marker || probe.cancelled_flag)
    // The same connection stays usable right after the cancellation.
    match e2e_execute(bridge, "echo__echo", []) {
      Ok(content) => assert_true(content.has_prefix("echo:"))
      Err(message) =>
        fail(
          "expected the connection to stay usable after cancel, got: " + message,
        )
    }
    bridge.close()
    // Contract 6 evidence: the bridge never sends notifications/cancelled
    // (the ext layer has no request-id correlation), so the fixture log must
    // not contain one — or must not exist at all.
    if notification_log != "" {
      match e2e_read_text(notification_log) {
        Some(text) => assert_false(text.contains("notifications/cancelled"))
        None => () // no notification ever reached the server: gap confirmed
      }
    }
  })
}

///|
async test "e2e cancellation keeps identity and the connection usable" {
  match e2e_find_node() {
    Some(node) => e2e_cancel_scenario(node, "")
    None => assert_true(true)
  }
}

///|
async test "e2e cancellation sends no cancelled notification" {
  match e2e_find_node() {
    Some(node) => {
      let root = @fs.tmpdir(prefix="posoco-mcp-e2e-notify")
      e2e_cancel_scenario(node, root + "/notifications.log")
    }
    None => assert_true(true)
  }
}
