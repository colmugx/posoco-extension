///|
/// Native end-to-end resilience tests: real node subprocesses running
/// test_fixtures/echo_server.mjs behind a tmpdir mcp.json, driven through the
/// same public path a host uses — discover → attach → activate →
/// &@posoco.ToolProvider list/execute.
///
/// These spawn real processes, so the whole suite is opt-in: every test skips
/// unless POSOCO_MCP_E2E=1 is set (node path overridable via
/// POSOCO_MCP_E2E_NODE). MCP_FIXTURE_RESILIENCE=1 is not an execution gate —
/// it is a variable handed to the fixture server's env to enable its
/// resilience behaviors (MCP_FIXTURE_FLAKY + MCP_FIXTURE_FLAKY_STATE gate the
/// flaky-initialize mode used by the probe-retry recovery test).
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
/// POSOCO_MCP_E2E_NODE). None → callers skip their scenario. POSOCO_MCP_E2E=1
/// gates the whole suite: spawning real node subprocesses is opt-in.
async fn e2e_find_node() -> String? {
  // POSOCO_MCP_E2E=1 opts in to spawning real node subprocesses; unset skips.
  match @env.get_env_var("POSOCO_MCP_E2E") {
    Some("1") => ()
    _ => return None
  }
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
  let bridge = match
    MCPToolBridge::discover(cwd~, user_mcp_json=cwd + "/nohome/.cetas/mcp.json") {
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
/// Collect the requestId of every `notifications/cancelled` in a fixture
/// notification log (one JSON-RPC message per line, recorded verbatim);
/// only notifications carrying a non-empty string requestId count.
fn e2e_cancelled_request_ids(log_text : String) -> Array[String] {
  let ids : Array[String] = []
  for line in log_text.split("\n") {
    let trimmed = line.trim()
    if trimmed.is_empty() {
      continue
    }
    let msg : Json = @json.parse(trimmed) catch { _ => continue }
    match msg {
      Object(fields) =>
        match fields.get("method") {
          Some(String("notifications/cancelled")) =>
            match fields.get("params") {
              Some(Object(params)) =>
                match params.get("requestId") {
                  Some(String(id)) => if !id.is_empty() { ids.push(id) }
                  _ => ()
                }
              _ => ()
            }
          _ => ()
        }
      _ => ()
    }
  }
  ids
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
    // Contract 6' evidence: the SDK abort path now best-effort notifies the
    // server before re-raising the cancellation, so the fixture log must
    // contain a notifications/cancelled whose requestId is a non-empty
    // string (string form of the in-flight request id, "client aborted").
    if notification_log != "" {
      let text = match e2e_read_text(notification_log) {
        Some(text) => text
        None => fail("expected a fixture notification log, none was written")
      }
      let ids = e2e_cancelled_request_ids(text)
      if ids.is_empty() {
        fail("fixture log has no notifications/cancelled with a requestId")
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
async test "e2e cancellation now delivers a cancelled notification" {
  match e2e_find_node() {
    Some(node) => {
      let root = @fs.tmpdir(prefix="posoco-mcp-e2e-notify")
      e2e_cancel_scenario(node, root + "/notifications.log")
    }
    None => assert_true(true)
  }
}

///|
/// Write a tmpdir mcp.json with the echo fixture plus a dead http server
/// (closed localhost port) to prove one probe's failure isolates the other.
async fn e2e_probe_fixture_cwd(node : String) -> String {
  let root = @fs.tmpdir(prefix="posoco-mcp-e2e-probe")
  let script = @fs.realpath("test_fixtures/echo_server.mjs") catch {
    _ => "test_fixtures/echo_server.mjs"
  }
  let content = "{\"mcpServers\":{\"echo\":{\"command\":\"\{node}\",\"args\":[\"\{script}\"],\"env\":{}},\"dead\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:1/mcp\",\"timeout_ms\":2000}}}"
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
/// Probe success path: start_probes without activate connects the fixture
/// server in the background; the live connection is executable afterwards.
async fn e2e_probe_success_scenario(node : String) -> Unit {
  @async.with_task_group(group => {
    let cwd = e2e_fixture_cwd(node, "", [])
    let bridge = match
      MCPToolBridge::discover(
        cwd~,
        user_mcp_json=cwd + "/nohome/.cetas/mcp.json",
      ) {
      Ok(bridge) => bridge
      Err(message) => fail("discover failed: " + message)
    }
    bridge.attach(group)
    bridge.start_probes()
    assert_true(bridge.pending.is_empty())
    let mut waited = 0
    while bridge.catalog_revision < 1 && waited < 5_000 {
      @async.sleep(25)
      waited += 25
    }
    assert_true(bridge.catalog_revision >= 1)
    assert_false(@posoco.ToolProvider::list_tools(bridge).is_empty())
    match e2e_execute(bridge, "echo__echo", []) {
      Ok(content) => assert_true(content.has_prefix("echo:"))
      Err(message) => fail("probe-connected echo failed: " + message)
    }
    bridge.close()
  })
}

///|
async test "e2e start_probes connects in background and stays executable" {
  match e2e_find_node() {
    Some(node) => e2e_probe_success_scenario(node)
    // skip: node is unavailable in this environment
    None => assert_true(true)
  }
}

///|
/// Probe failure isolation: a dead server's failed probe is recorded while
/// the parallel echo probe connects and executes unaffected. A short
/// injected retry schedule keeps the dead server's bounded retries inside
/// the settle window; the stability wait skips past its intermediate
/// failure entries before asserting the single final one.
async fn e2e_probe_failure_isolation_scenario(node : String) -> Unit {
  @async.with_task_group(group => {
    let cwd = e2e_probe_fixture_cwd(node)
    let bridge = match
      MCPToolBridge::discover(
        cwd~,
        user_mcp_json=cwd + "/nohome/.cetas/mcp.json",
      ) {
      Ok(bridge) => bridge
      Err(message) => fail("discover failed: " + message)
    }
    bridge.attach(group)
    bridge.start_probes(backoff_ms=[100, 100, 100])
    let mut waited = 0
    while (bridge.catalog_revision < 1 || bridge.failures().length() < 1) &&
          waited < 5_000 {
      @async.sleep(25)
      waited += 25
    }
    let mut last_len = bridge.failures().length()
    let mut stable = 0
    while stable < 400 && waited < 10_000 {
      @async.sleep(25)
      waited += 25
      let len = bridge.failures().length()
      if len == last_len {
        stable += 25
      } else {
        last_len = len
        stable = 0
      }
    }
    // Echo's probe succeeded; the dead server exhausted its retries into
    // exactly one final failure entry.
    assert_true(bridge.catalog_revision >= 1)
    assert_eq(bridge.failures().length(), 1)
    assert_eq(bridge.failures()[0].0, "dead")
    assert_false(@posoco.ToolProvider::list_tools(bridge).is_empty())
    match e2e_execute(bridge, "echo__echo", []) {
      Ok(content) => assert_true(content.has_prefix("echo:"))
      Err(message) =>
        fail("echo must survive the dead server's probe failure: " + message)
    }
    bridge.close()
  })
}

///|
async test "e2e probe failure isolates the healthy server" {
  match e2e_find_node() {
    Some(node) => e2e_probe_failure_isolation_scenario(node)
    None => assert_true(true)
  }
}

///|
/// Probe retry recovery: the fixture rejects its first initialize attempt
/// (dies without a reply, counted across restarts in a state file), so the
/// first probe fails — the background retry then connects the recovered
/// server, scrubs the failure entry, and the live connection executes.
async fn e2e_probe_flaky_recovery_scenario(node : String) -> Unit {
  @async.with_task_group(group => {
    let state_root = @fs.tmpdir(prefix="posoco-mcp-e2e-flaky")
    let state_path = state_root + "/flaky_state"
    let cwd = e2e_fixture_cwd(node, "", [
      ("MCP_FIXTURE_FLAKY", "1"),
      ("MCP_FIXTURE_FLAKY_STATE", state_path),
    ])
    let bridge = match
      MCPToolBridge::discover(
        cwd~,
        user_mcp_json=cwd + "/nohome/.cetas/mcp.json",
      ) {
      Ok(bridge) => bridge
      Err(message) => fail("discover failed: " + message)
    }
    bridge.attach(group)
    // First backoff stays well above the flaky process's time-to-EOF so the
    // retry cannot race the dying first attempt.
    bridge.start_probes(backoff_ms=[400, 250, 250])
    let mut waited = 0
    while bridge.catalog_revision < 1 && waited < 10_000 {
      @async.sleep(25)
      waited += 25
    }
    // The retry bumped the revision and scrubbed the first failure in the
    // same synchronous step, so /mcp reflects a fully recovered server.
    assert_true(bridge.catalog_revision >= 1)
    assert_true(bridge.failures().is_empty())
    assert_false(@posoco.ToolProvider::list_tools(bridge).is_empty())
    match e2e_execute(bridge, "echo__echo", []) {
      Ok(content) => assert_true(content.has_prefix("echo:"))
      Err(message) => fail("flaky-recovered echo failed: " + message)
    }
    bridge.close()
  })
}

///|
/// Explicit-connect fixture config: the caller picks the name, env knobs,
/// and deadline, so registry slot order is exactly the connect call order
/// (deterministic, unlike mcp.json map iteration order).
fn e2e_fixture_config(
  node : String,
  script : String,
  name~ : String,
  resilience~ : Bool,
  timeout_ms~ : Int,
) -> MCPServerConfig {
  let env : Map[String, String] = if resilience {
    Map::from_array([("MCP_FIXTURE_RESILIENCE", "1")])
  } else {
    Map::from_array([])
  }
  MCPServerConfig::MCPServerConfig(
    name~,
    transport=@transport.AnyTransport::StdioClient(
      @transport.StdioClientTransport::StdioClientTransport(
        cmd=node,
        args=[script],
        extra_env=env,
      ),
    ),
    auth=ServerAuth::NoAuth,
    timeout_ms~,
  )
}

///|
/// Slot-registry contract: an in-flight execute on one server while a
/// NEIGHBOR is `reconnect_server`d must never land on the wrong server or a
/// shifted index. The neighbor sits at slot 0 and the victim (a slow call
/// under a tight deadline) at slot 1, so a remove()-and-shift registry would
/// move the victim's index under the in-flight call; the neighbor carries no
/// `sleep` tool, so a misrouted retry would surface as its "echo:{}" success
/// instead of the victim's own timeout.
async fn e2e_neighbor_reconnect_scenario(node : String) -> Unit {
  @async.with_task_group(group => {
    let script = @fs.realpath("test_fixtures/echo_server.mjs") catch {
      _ => "test_fixtures/echo_server.mjs"
    }
    let bridge = MCPToolBridge()
    bridge.attach(group)
    match
      bridge.connect(
        e2e_fixture_config(
          node,
          script,
          name="echo",
          resilience=false,
          timeout_ms=10_000,
        ),
        group,
      ) {
      Ok(_) => ()
      Err(message) => fail("connect echo failed: " + message)
    }
    match
      bridge.connect(
        e2e_fixture_config(
          node,
          script,
          name="slow",
          resilience=true,
          timeout_ms=300,
        ),
        group,
      ) {
      Ok(_) => ()
      Err(message) => fail("connect slow failed: " + message)
    }
    assert_eq(bridge.connections.length(), 2)
    let names : Array[String] = []
    for tool in @posoco.ToolProvider::list_tools(bridge) {
      names.push(tool.name.to_string())
    }
    assert_true(names.contains("echo__echo"))
    assert_false(names.contains("echo__sleep"))
    assert_true(names.contains("slow__sleep"))
    let settled : Array[Result[String, String]] = []
    let _ = group.spawn(() => {
      settled.push(
        e2e_execute(bridge, "slow__sleep", [("ms", Json::number(5000))]),
      )
    })
    @async.sleep(100)
    match bridge.reconnect_server("echo") {
      Ok(_) => ()
      Err(message) => fail("neighbor reconnect failed: " + message)
    }
    let mut waited = 0
    while settled.is_empty() && waited < 8_000 {
      @async.sleep(25)
      waited += 25
    }
    assert_eq(settled.length(), 1)
    match settled[0] {
      Err(message) =>
        assert_true(
          message.contains("stage=timeout") &&
          message.contains("timeout_ms=300"),
        )
      Ok(content) => fail("sleep must surface its own timeout, got: " + content)
    }
    // Slot identities never drifted: the neighbor refilled its own slot, the
    // victim kept its index through its reactive reconnect, and routing maps
    // each server's tools back to its original slot.
    assert_eq(bridge.connections.length(), 2)
    assert_eq(bridge.connections[0].name, "echo")
    assert_eq(bridge.connections[1].name, "slow")
    assert_true(bridge.connections[0].client is Some(_))
    assert_true(bridge.connections[1].client is Some(_))
    assert_true(bridge.tool_to_conn.get("echo__echo") is Some(0))
    assert_true(bridge.tool_to_conn.get("slow__echo") is Some(1))
    match e2e_execute(bridge, "echo__echo", []) {
      Ok(content) => assert_true(content.has_prefix("echo:"))
      Err(message) => fail("neighbor echo failed after refill: " + message)
    }
    match e2e_execute(bridge, "slow__echo", []) {
      Ok(content) => assert_true(content.has_prefix("echo:"))
      Err(message) => fail("victim echo failed after scenario: " + message)
    }
    bridge.close()
  })
}

///|
async test "e2e neighbor reconnect during in-flight call stays slot-honest" {
  match e2e_find_node() {
    Some(node) => e2e_neighbor_reconnect_scenario(node)
    // skip: node is unavailable in this environment
    None => assert_true(true)
  }
}

///|
async test "e2e probe retry recovers a flaky server" {
  match e2e_find_node() {
    Some(node) => e2e_probe_flaky_recovery_scenario(node)
    None => assert_true(true)
  }
}

///|
/// The folded view of slot 0's actor: the deterministic observation seam for
/// the wiring-level actor tests (health/generation/in_flight).
async fn e2e_conn_view(bridge : MCPToolBridge) -> ConnView {
  let actor = match bridge.connections[0].actor {
    Some(actor) => actor
    None => fail("expected slot 0 to hold a live actor")
  }
  match actor.inspect(timeout_ms=10_000) {
    Ok(View(view)) => view
    _ => fail("conn actor inspect did not answer a view")
  }
}

///|
/// True once slot 0's actor folded to Reconnecting (bounded poll).
async fn e2e_wait_reconnecting(bridge : MCPToolBridge) -> Bool {
  let mut waited = 0
  while waited < 5_000 {
    if e2e_conn_view(bridge).health is Reconnecting {
      return true
    }
    @async.sleep(10)
    waited += 10
  }
  false
}

///|
/// Wiring-level arbitration: two concurrent reconnect runners on the same
/// live slot — the actor's BeginReconnect grants exactly one winner; the
/// loser is refused with Busy immediately (the legacy "already in progress"
/// text) and never opens a second connection. The winner settles the slot
/// back to Fresh with the paired admission counts, and the connection keeps
/// serving calls.
async fn e2e_dual_reconnect_scenario(node : String) -> Unit {
  @async.with_task_group(group => {
    let bridge = e2e_activate_bridge(group, node, "", [
      ("MCP_FIXTURE_RESILIENCE", "1"),
    ])
    let results : Array[Result[Unit, String]] = []
    let _ = group.spawn(() => results.push(bridge.reconnect_one(0)))
    assert_true(e2e_wait_reconnecting(bridge))
    // The loser: refused by the actor fold, not by a check-then-act flag.
    match bridge.reconnect_one(0) {
      Err(message) => assert_true(message.contains("already in progress"))
      Ok(_) => fail("expected the second reconnect to lose with Busy")
    }
    let mut waited = 0
    while results.is_empty() && waited < 8_000 {
      @async.sleep(25)
      waited += 25
    }
    assert_eq(results.length(), 1)
    match results[0] {
      Ok(_) => ()
      Err(message) => fail("winner reconnect failed: " + message)
    }
    let view = e2e_conn_view(bridge)
    assert_true(view.health is Fresh)
    assert_eq(view.in_flight, 0)
    assert_eq(bridge.connections.length(), 1)
    match e2e_execute(bridge, "echo__echo", []) {
      Ok(content) => assert_true(content.has_prefix("echo:"))
      Err(message) => fail("post-reconnect echo failed: " + message)
    }
    bridge.close()
  })
}

///|
async test "e2e concurrent reconnects on one slot have a single winner" {
  match e2e_find_node() {
    Some(node) => e2e_dual_reconnect_scenario(node)
    None => assert_true(true)
  }
}

///|
/// Wiring-level stigma scoping (distinct from the A2 pure-fold tests): with
/// the retry budget at 0, a timed-out call stigmatizes exactly its own
/// generation (NeedsReconnect, admission paired back to zero) and the NEXT
/// call's forced reconnect mints the successor generation as Fresh — a
/// stigma that smeared onto the successor would resurface as another forced
/// reconnect.
async fn e2e_stigma_generation_scenario(node : String) -> Unit {
  @async.with_task_group(group => {
    let bridge = e2e_activate_bridge(
      group,
      node,
      ",\"timeout_ms\":300,\"max_reconnects\":0",
      [("MCP_FIXTURE_RESILIENCE", "1")],
    )
    match e2e_execute(bridge, "echo__sleep", [("ms", Json::number(5000))]) {
      Err(message) => assert_true(message.contains("stage=timeout"))
      Ok(content) => fail("sleep should have timed out, got: " + content)
    }
    let stained = e2e_conn_view(bridge)
    assert_true(stained.health is NeedsReconnect)
    assert_eq(stained.in_flight, 0)
    // The forced reconnect of the next call recovers into a Fresh successor
    // generation; the dead generation's stigma is structurally inert.
    match e2e_execute(bridge, "echo__echo", []) {
      Ok(content) => assert_true(content.has_prefix("echo:"))
      Err(message) =>
        fail("expected forced reconnect to recover, got: " + message)
    }
    let recovered = e2e_conn_view(bridge)
    assert_true(recovered.health is Fresh)
    assert_eq(recovered.generation, stained.generation + 1)
    assert_eq(recovered.in_flight, 0)
    bridge.close()
  })
}

///|
async test "e2e timeout stigma lands on its generation and clears with it" {
  match e2e_find_node() {
    Some(node) => e2e_stigma_generation_scenario(node)
    None => assert_true(true)
  }
}

///|
/// Wiring-level cancel pairing: a cancelled in-flight call returns its
/// admission through the deferred EndCall (in_flight back to 0, no stigma —
/// an unobservable outcome reports TransportFail, never TimedOut), so the
/// very next call runs on the SAME generation without a forced reconnect.
async fn e2e_cancel_pairing_scenario(node : String) -> Unit {
  @async.with_task_group(group => {
    let bridge = e2e_activate_bridge(group, node, "", [
      ("MCP_FIXTURE_RESILIENCE", "1"),
    ])
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
          probe.cancelled_flag = @async.is_being_cancelled()
        }
      }
    })
    @async.sleep(300)
    task.cancel()
    let mut waited = 0
    while !probe.settled && waited < 5_000 {
      @async.sleep(25)
      waited += 25
    }
    assert_true(probe.settled)
    assert_true(probe.raised)
    let after_cancel = e2e_conn_view(bridge)
    assert_eq(after_cancel.in_flight, 0)
    assert_true(after_cancel.health is Fresh)
    match e2e_execute(bridge, "echo__echo", []) {
      Ok(content) => assert_true(content.has_prefix("echo:"))
      Err(message) =>
        fail("expected usable connection after cancel, got: " + message)
    }
    // No forced reconnect happened: the cancel path returned its admission
    // without stigmatizing the generation.
    let after_reuse = e2e_conn_view(bridge)
    assert_true(after_reuse.health is Fresh)
    assert_eq(after_reuse.generation, after_cancel.generation)
    assert_eq(after_reuse.in_flight, 0)
    bridge.close()
  })
}

///|
async test "e2e cancelled call returns its admission without stigmatizing" {
  match e2e_find_node() {
    Some(node) => e2e_cancel_pairing_scenario(node)
    None => assert_true(true)
  }
}

///|
/// Wiring-level actor-close honesty: with ONLY the slot's actor closed (the
/// state a retire leaves behind mid-flight), routing and the client mirror
/// still resolve, so the failure must surface through the ask mapping —
/// MailboxClosed becomes an honest stage=transport failure for calls and an
/// honest error for refresh — never a swallowed success or a hang.
async fn e2e_actor_close_scenario(node : String) -> Unit {
  @async.with_task_group(group => {
    let bridge = e2e_activate_bridge(group, node, "", [
      ("MCP_FIXTURE_RESILIENCE", "1"),
    ])
    match bridge.connections[0].actor {
      Some(actor) => actor.close()
      None => fail("expected slot 0 to hold a live actor")
    }
    match e2e_execute(bridge, "echo__echo", []) {
      Err(message) => assert_true(message.contains("stage=transport"))
      Ok(content) =>
        fail("expected honest failure after actor close, got: " + content)
    }
    match bridge.refresh_tools() {
      Err(message) => assert_true(message.contains("refresh list_tools failed"))
      Ok(_) => fail("expected refresh to fail honestly after actor close")
    }
    bridge.close()
  })
}

///|
async test "e2e closed actor makes calls and refresh fail honestly" {
  match e2e_find_node() {
    Some(node) => e2e_actor_close_scenario(node)
    None => assert_true(true)
  }
}

///|
/// Slot 0's actor handle, saved before a close the test wants to observe
/// through the detached handle (late tells, second join, snapshot).
fn e2e_slot0_actor(
  bridge : MCPToolBridge,
) -> ConnActor[@client.MCPClient] raise {
  match bridge.connections[0].actor {
    Some(actor) => actor
    None => fail("expected slot 0 to hold a live actor")
  }
}

///|
/// Wave 4 close discipline, wiring level. A queued-before-close EndCall
/// folds during the drain; `close(); join()` returning IS the drain
/// confirmation, a second join returns the recorded Graceful immediately
/// (multi-waiter safe), late tells are refused with MailboxClosed, and the
/// snapshot closes the conservation law (accepted == processed, abandoned
/// == 0 — a graceful drain serves everything it accepted). The /mcp status
/// read before the close pins the Inspect data source end to end.
async fn e2e_close_drain_scenario(node : String) -> Unit {
  @async.with_task_group(group => {
    let bridge = e2e_activate_bridge(group, node, "", [
      ("MCP_FIXTURE_RESILIENCE", "1"),
    ])
    let outcome = @posoco.CommandPort::invoke(bridge, "mcp", Json::null()) catch {
      error => fail("mcp status failed: " + error.to_string())
    }
    match outcome {
      Success(feedback~, ..) => {
        assert_true(feedback.contains("- echo: connected"))
        assert_true(feedback.contains("health=fresh"))
        assert_true(feedback.contains("generation=0"))
      }
      _ => fail("expected a successful status outcome")
    }
    let actor = e2e_slot0_actor(bridge)
    // One admitted call, its report queued before the close: exactly what
    // an in-flight execute holds when a shutdown races it.
    match actor.acquire(timeout_ms=10_000) {
      Ok(Permit(permit)) => {
        assert_eq(permit.generation, 0)
        match actor.inspect(timeout_ms=10_000) {
          Ok(View(view)) => assert_eq(view.in_flight, 1)
          _ => fail("inspect did not answer a view")
        }
        let _ = actor.end_call(generation=0, outcome=CallOk)
      }
      _ => fail("acquire did not answer a permit")
    }
    bridge.close()
    assert_true(bridge.connections.is_empty())
    // The late report is refused — never re-delivered to the dead mailbox.
    assert_eq(
      actor.end_call(generation=0, outcome=CallOk),
      Err(@fuwaroid.SendRefusal::MailboxClosed),
    )
    // Second join: the loop already terminated, so it returns the recorded
    // reason immediately.
    let reason = actor.join()
    guard reason is Graceful else { fail("close drain expected Graceful") }
    let snap = actor.snapshot()
    guard snap.lifecycle is Stopped(Graceful) else {
      fail("expected Stopped(Graceful) lifecycle")
    }
    assert_eq(snap.abandoned, 0L)
    assert_eq(snap.outstanding, 0L)
    assert_eq(snap.accepted, snap.processed)
  })
}

///|
async test "e2e close drains the actor folds queued reports and refuses late tells" {
  match e2e_find_node() {
    Some(node) => e2e_close_drain_scenario(node)
    None => assert_true(true)
  }
}

///|
/// Wave 4 close discipline against a REAL in-flight call: an execute
/// admitted and parked on echo__sleep when close lands must settle with an
/// honest failure of its own — never a false success, never a hang — while
/// close still returns through a Graceful drain. The exact stage depends
/// on whether the request had reached the wire before the transport
/// closed: a sent request parks until its own deadline (`stage=timeout`;
/// the SDK's close does not fail parked response waiters — the client
/// event loop breaks on EOF without failing pending queues), an unsent
/// one fails the send (`stage=transport`). The racing EndCall either
/// queued before the mailbox closed and folded, or was refused after it —
/// neither disturbs the loop.
async fn e2e_close_inflight_scenario(node : String) -> Unit {
  @async.with_task_group(group => {
    let bridge = e2e_activate_bridge(group, node, ",\"timeout_ms\":2000", [
      ("MCP_FIXTURE_RESILIENCE", "1"),
    ])
    let actor = e2e_slot0_actor(bridge)
    let settled : Array[Result[String, String]] = []
    let _ = group.spawn(() => {
      settled.push(
        e2e_execute(bridge, "echo__sleep", [("ms", Json::number(60_000))]),
      )
    })
    let mut admitted = false
    let mut waited = 0
    while waited < 1_000 {
      match actor.inspect(timeout_ms=10_000) {
        Ok(View(view)) =>
          if view.in_flight >= 1 {
            admitted = true
            break
          }
        _ => fail("inspect did not answer a view")
      }
      @async.sleep(5)
      waited += 5
    }
    assert_true(admitted)
    bridge.close()
    let reason = actor.join()
    guard reason is Graceful else { fail("close drain expected Graceful") }
    assert_true(bridge.connections.is_empty())
    let mut settled_wait = 0
    while settled.is_empty() && settled_wait < 6_000 {
      @async.sleep(25)
      settled_wait += 25
    }
    assert_eq(settled.length(), 1)
    match settled[0] {
      Err(message) =>
        assert_true(
          message.contains("stage=timeout") ||
          message.contains("stage=transport"),
        )
      Ok(content) =>
        fail("the in-flight call must fail honestly on close, got: " + content)
    }
  })
}

///|
async test "e2e close with an in-flight call settles it as an honest transport failure" {
  match e2e_find_node() {
    Some(node) => e2e_close_inflight_scenario(node)
    None => assert_true(true)
  }
}
