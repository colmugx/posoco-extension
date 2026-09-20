///|
/// Whitebox tests for the composition-time background probe entry
/// (`start_probes`) and the no-attach group contract of the other startup
/// entries (`activate`, `reconnect_server`). No file I/O — bridges are built
/// from direct struct literals so the suite runs on every target.

///|
/// A stdio config whose command never exists, so a spawned probe fails fast
/// on every target.
fn probe_test_config(name : String) -> MCPServerConfig {
  MCPServerConfig::MCPServerConfig(
    name~,
    transport=@transport.AnyTransport::StdioClient(
      @transport.StdioClientTransport::StdioClientTransport(
        cmd="definitely-missing-probe-cmd",
        args=[],
        extra_env=Map::from_array([]),
      ),
    ),
    auth=ServerAuth::NoAuth,
  )
}

///|
/// An http config for the no-attach scenarios: the URL is never dialed —
/// the missing task group guard fires before any connect attempt.
fn probe_test_http_config(name : String) -> MCPServerConfig {
  MCPServerConfig::MCPServerConfig(
    name~,
    transport=@transport.AnyTransport::HttpClient(
      @transport.HttpClientTransport::HttpClientTransport(
        "http://127.0.0.1:9/mcp",
        auth_token="",
        extra_headers=[],
      ),
    ),
    auth=ServerAuth::NoAuth,
  )
}

///|
fn probe_test_bridge_with_configs(
  mode~ : LoadMode,
  pending : Array[MCPServerConfig],
) -> MCPToolBridge {
  MCPToolBridge::{
    connections: [],
    tool_to_conn: Map::from_array([]),
    mode,
    pending,
    group: None,
    activated: false,
    catalog_revision: 0,
    startup_failures: [],
    server_tokens: Map::from_array([]),
    auth_challenges: Map::from_array([]),
    configs: Map::from_array([]),
  }
}

///|
fn probe_test_bridge(
  mode~ : LoadMode,
  server_names : Array[String],
) -> MCPToolBridge {
  let pending : Array[MCPServerConfig] = []
  for name in server_names {
    pending.push(probe_test_config(name))
  }
  probe_test_bridge_with_configs(mode~, pending)
}

///|
async test "start_probes_without_attach_records_skip_failures" {
  let bridge = probe_test_bridge(mode=LoadMode::Lazy, ["a", "b"])
  bridge.start_probes()
  assert_true(bridge.activated)
  assert_true(bridge.pending.is_empty())
  assert_eq(bridge.startup_failures.length(), 2)
  assert_true(bridge.startup_failures[0].0 == "a")
  assert_true(bridge.startup_failures[1].0 == "b")
  for pair in bridge.startup_failures {
    assert_true(pair.1.contains("not attached to a task group"))
  }
  assert_eq(bridge.catalog_revision, 0)
  // Nothing was spawned, so no retry can add entries later.
  @async.sleep(50)
  assert_eq(bridge.startup_failures.length(), 2)
}

///|
/// Q1 group contract: activating without `attach` records an honest
/// "needs a task group" failure for EVERY pending server — http configs no
/// longer sneak through on the old group-less direct-connect form.
async test "activate_without_attach_fails_http_servers_honestly" {
  let pending : Array[MCPServerConfig] = [
    probe_test_http_config("h1"),
    probe_test_http_config("h2"),
  ]
  let bridge = probe_test_bridge_with_configs(mode=LoadMode::Eager, pending)
  let failures = bridge.activate()
  assert_true(bridge.activated)
  assert_eq(failures.length(), 2)
  assert_true(failures[0].0 == "h1")
  assert_true(failures[1].0 == "h2")
  for pair in failures {
    assert_true(pair.1.contains("needs a task group"))
    assert_true(pair.1.contains("call attach first"))
  }
  // Nothing silently connected and the empty catalog is still announced.
  assert_true(bridge.connections.is_empty())
  assert_eq(bridge.catalog_revision, 1)
}

///|
/// Q1 group contract: `reconnect_server` without `attach` fails honestly,
/// and the precondition fires before any destructive work — no slot is
/// retired and the revision never moves.
async test "reconnect_server_without_attach_fails_honestly" {
  let bridge = MCPToolBridge::{
    connections: [],
    tool_to_conn: Map::from_array([]),
    mode: LoadMode::Eager,
    pending: [],
    group: None,
    activated: true,
    catalog_revision: 0,
    startup_failures: [],
    server_tokens: Map::from_array([]),
    auth_challenges: Map::from_array([]),
    configs: Map::from_array([("solo", probe_test_http_config("solo"))]),
  }
  match bridge.reconnect_server("solo") {
    Err(message) => {
      assert_true(message.contains("needs a task group"))
      assert_true(message.contains("solo"))
    }
    Ok(_) => fail("expected no-group reconnect to fail honestly")
  }
  assert_eq(bridge.catalog_revision, 0)
  // An unknown server keeps its distinct error, group or not.
  match bridge.reconnect_server("nope") {
    Err(message) => assert_true(message.contains("not configured"))
    Ok(_) => fail("expected unknown-server rejection")
  }
}

///|
async test "start_probes_returns_before_connections_settle" {
  @async.with_task_group(group => {
    let bridge = probe_test_bridge(mode=LoadMode::Lazy, ["bogus"])
    bridge.attach(group)
    bridge.start_probes()
    // Claimed synchronously: pending is drained and no connection has
    // settled (a successful probe would have bumped the revision).
    assert_true(bridge.activated)
    assert_true(bridge.pending.is_empty())
    assert_eq(bridge.catalog_revision, 0)
    let mut waited = 0
    while bridge.startup_failures.length() == 0 && waited < 5_000 {
      @async.sleep(25)
      waited += 25
    }
    assert_eq(bridge.startup_failures.length(), 1)
    assert_eq(bridge.startup_failures[0].0, "bogus")
    // A failed probe never bumps the revision.
    assert_eq(bridge.catalog_revision, 0)
  })
}

///|
async test "on_start_after_start_probes_adds_nothing" {
  let bridge = probe_test_bridge(mode=LoadMode::Lazy, ["x"])
  bridge.start_probes()
  let failures_before = bridge.startup_failures.length()
  let revision_before = bridge.catalog_revision
  bridge.on_start()
  assert_eq(bridge.startup_failures.length(), failures_before)
  assert_eq(bridge.catalog_revision, revision_before)
}

///|
/// Exhausted retries with an unreachable stdio server: intermediate failure
/// entries are scrubbed, so exactly ONE final entry per server remains and
/// the revision never moves. A 300ms stable window proves the injected
/// schedule (3 retries) ran to exhaustion.
async test "start_probes_exhausted_retries_leave_one_failure_per_server" {
  @async.with_task_group(group => {
    let bridge = probe_test_bridge(mode=LoadMode::Lazy, ["s1", "s2"])
    bridge.attach(group)
    bridge.start_probes(backoff_ms=[10, 10, 10])
    let mut waited = 0
    let mut last_len = bridge.startup_failures.length()
    let mut stable = 0
    while waited < 5_000 && stable < 300 {
      @async.sleep(25)
      waited += 25
      let len = bridge.startup_failures.length()
      if len == last_len {
        stable += 25
      } else {
        last_len = len
        stable = 0
      }
    }
    assert_eq(bridge.startup_failures.length(), 2)
    let mut seen_s1 = 0
    let mut seen_s2 = 0
    for pair in bridge.startup_failures {
      if pair.0 == "s1" {
        seen_s1 += 1
      }
      if pair.0 == "s2" {
        seen_s2 += 1
      }
    }
    assert_eq(seen_s1, 1)
    assert_eq(seen_s2, 1)
    assert_eq(bridge.catalog_revision, 0)
  })
}

///|
/// Deterministic exhaustion branch through the retry helper directly: with
/// backoff [0, 0, 0] four attempts each record an entry, then the final
/// scrub leaves exactly the last one.
async test "retry_startup_probe_exhaustion_keeps_single_final_entry" {
  let bridge = probe_test_bridge(mode=LoadMode::Lazy, [])
  bridge.retry_startup_probe(probe_test_config("bogus"), "first", [0, 0, 0])
  assert_eq(bridge.startup_failures.length(), 1)
  assert_eq(bridge.startup_failures[0].0, "bogus")
  assert_eq(bridge.catalog_revision, 0)
}

///|
/// The recovery scrub removes every entry of the named server and keeps the
/// others (the e2e suite proves the success path end to end).
async test "scrub_startup_failures_removes_only_named_server" {
  let bridge = probe_test_bridge(mode=LoadMode::Lazy, [])
  bridge.startup_failures.push(("a", "x"))
  bridge.startup_failures.push(("b", "y"))
  bridge.startup_failures.push(("a", "z"))
  bridge.scrub_startup_failures("a")
  assert_eq(bridge.startup_failures.length(), 1)
  assert_eq(bridge.startup_failures[0].0, "b")
}
