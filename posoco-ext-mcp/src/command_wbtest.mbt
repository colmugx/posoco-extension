///|
fn http_config(name : String) -> MCPServerConfig {
  {
    name,
    transport: @transport.AnyTransport::HttpClient(
      @transport.HttpClientTransport::HttpClientTransport(
        "https://example.invalid/mcp",
      ),
    ),
    auth: ServerAuth::NoAuth,
    era: @client.ProtocolEra::Auto,
    timeout_ms: 30_000,
    max_reconnects: 1,
  }
}

///|
fn test_conn_stats(
  tools? : Int = 2,
  health? : ConnHealth = Fresh,
  generation? : Int = 0,
  in_flight? : Int = 0,
  accepted? : Int64 = 3L,
  processed? : Int64 = 3L,
  abandoned? : Int64 = 0L,
) -> McpConnStats {
  { tools, health, generation, in_flight, accepted, processed, abandoned, }
}

///|
test "format_mcp_status renders connected retired failed and pending rows" {
  let rows : Array[McpStatusRow] = [
    { name: "github", state: Connected(test_conn_stats(tools=45)), },
    { name: "gone", state: Retired, },
    { name: "context7", state: Failed("MCP connect failed for 'context7'"), },
    { name: "exa", state: Pending, },
  ]
  inspect(
    format_mcp_status(LoadMode::Lazy, rows),
    content=(
      #|4 servers: 1 connected, 1 retired, 1 failed, 1 pending
      #|- github: connected, 45 tools (health=fresh, generation=0, in_flight=0, accepted=3, processed=3, abandoned=0)
      #|- gone: retired
      #|- context7: failed — MCP connect failed for 'context7'
      #|- exa: pending (connects on first turn)
    ),
  )
}

///|
test "format_mcp_status carries the folded health domain per connection" {
  let rows : Array[McpStatusRow] = [
    {
      name: "stained",
      state: Connected(
        test_conn_stats(
          tools=1,
          health=NeedsReconnect,
          generation=3,
          in_flight=2,
          accepted=9L,
          processed=7L,
          abandoned=0L,
        ),
      ),
    },
    {
      name: "reconnecting",
      state: Connected(
        test_conn_stats(tools=0, health=Reconnecting, generation=4, in_flight=1),
      ),
    },
  ]
  inspect(
    format_mcp_status(LoadMode::Eager, rows),
    content=(
      #|2 servers: 2 connected, 0 retired, 0 failed, 0 pending
      #|- stained: connected, 1 tool (health=needs-reconnect, generation=3, in_flight=2, accepted=9, processed=7, abandoned=0)
      #|- reconnecting: connected, 0 tools (health=reconnecting, generation=4, in_flight=1, accepted=3, processed=3, abandoned=0)
    ),
  )
}

///|
test "format_mcp_status singular server and tool counts" {
  let rows : Array[McpStatusRow] = [
    { name: "exa", state: Connected(test_conn_stats(tools=1)), },
  ]
  inspect(
    format_mcp_status(LoadMode::Eager, rows),
    content=(
      #|1 server: 1 connected, 0 retired, 0 failed, 0 pending
      #|- exa: connected, 1 tool (health=fresh, generation=0, in_flight=0, accepted=3, processed=3, abandoned=0)
    ),
  )
}

///|
test "format_mcp_status with no servers" {
  inspect(
    format_mcp_status(LoadMode::Lazy, []),
    content="no MCP servers configured",
  )
}

///|
test "mcp_status_json carries per-server state and connection domain" {
  let rows : Array[McpStatusRow] = [
    {
      name: "github",
      state: Connected(
        test_conn_stats(
          tools=2,
          health=NeedsReconnect,
          generation=3,
          in_flight=1,
          accepted=9L,
          processed=7L,
          abandoned=1L,
        ),
      ),
    },
    { name: "gone", state: Retired, },
    { name: "exa", state: Failed("MCP connect failed for 'exa'"), },
  ]
  inspect(
    mcp_status_json(LoadMode::Lazy, rows).stringify(),
    content="{\"kind\":\"mcp_status\",\"mode\":\"lazy\",\"servers\":[{\"name\":\"github\",\"status\":\"connected\",\"tools\":2,\"health\":\"needs-reconnect\",\"generation\":3,\"in_flight\":1,\"accepted\":9,\"processed\":7,\"abandoned\":1},{\"name\":\"gone\",\"status\":\"retired\"},{\"name\":\"exa\",\"status\":\"failed\",\"reason\":\"MCP connect failed for 'exa'\"}]}",
  )
}

///|
async test "status_rows maps failures and pending before activation" {
  let bridge : MCPToolBridge = {
    connections: [],
    tool_to_conn: Map::from_array([]),
    mode: LoadMode::Lazy,
    pending: [http_config("exa")],
    group: None,
    activated: false,
    catalog_revision: 0,
    startup_failures: [("github", "MCP connect failed for 'github'")],
    server_tokens: Map::from_array([]),
    auth_challenges: Map::from_array([]),
    configs: Map::from_array([]),
  }
  let rows = bridge.status_rows()
  inspect(rows.length(), content="2")
  inspect(rows[0].name, content="github")
  inspect(mcp_row_status_label(rows[0].state), content="failed")
  inspect(rows[1].name, content="exa")
  inspect(mcp_row_status_label(rows[1].state), content="pending")
  // After activation every declared server has settled into a connection
  // or a failure row, so the pending copy must not double-report.
  bridge.activated = true
  inspect(bridge.status_rows().length(), content="1")
}

///|
/// A retired slot (no client, no actor — what `retire_slot` and a failed
/// `reconnect_server` refill leave behind) displays as retired: the Wave A1
/// transitional "connected, 0 tools" distortion is gone.
async test "status_rows displays retired slots as retired" {
  let bridge = registry_test_bridge(
    [
      registry_test_conn("gone", [catalog_test_tool("gone__tool")]),
      registry_test_conn("live-shell", []),
    ],
    [],
  )
  let rows = bridge.status_rows()
  inspect(rows.length(), content="2")
  inspect(rows[0].name, content="gone")
  inspect(mcp_row_status_label(rows[0].state), content="retired")
  inspect(rows[1].name, content="live-shell")
  inspect(mcp_row_status_label(rows[1].state), content="retired")
}

///|
/// A bridge that never attached has no actors anywhere; reading status must
/// stay on the retired/pending display path instead of touching an ask.
async test "status_rows on a never-attached bridge stays on retired paths" {
  let bridge : MCPToolBridge = {
    connections: [registry_test_conn("solo", [])],
    tool_to_conn: Map::from_array([]),
    mode: LoadMode::Eager,
    pending: [],
    group: None,
    activated: true,
    catalog_revision: 0,
    startup_failures: [],
    server_tokens: Map::from_array([]),
    auth_challenges: Map::from_array([]),
    configs: Map::from_array([]),
  }
  let outcome = @posoco.CommandPort::invoke(bridge, "mcp", Json::null()) catch {
    error => fail("invoke failed: " + error.to_string())
  }
  match outcome {
    Success(feedback~, ..) =>
      inspect(
        feedback,
        content=(
          #|1 server: 0 connected, 1 retired, 0 failed, 0 pending
          #|- solo: retired
        ),
      )
    _ => fail("expected success")
  }
}

///|
async test "mcp command declares itself and rejects unknown actions and ids" {
  let bridge = MCPToolBridge::MCPToolBridge()
  let defs = @posoco.CommandPort::commands(bridge)
  inspect(defs.length(), content="1")
  inspect(defs[0].id, content="mcp")
  let outcome = @posoco.CommandPort::invoke(
    bridge,
    "mcp",
    Json::object(Map::from_array([("action", Json::string("bogus"))])),
  ) catch {
    error => fail("invoke failed: " + error.to_string())
  }
  match outcome {
    Failure(reason~) =>
      inspect(
        reason,
        content="mcp: unknown action 'bogus' (expected list or refresh)",
      )
    _ => fail("expected failure for unknown action")
  }
  try @posoco.CommandPort::invoke(bridge, "other", Json::null()) catch {
    error => inspect(error.to_string(), content="CommandError::NotFound(other)")
  } noraise {
    _ => fail("expected NotFound")
  }
}

///|
async test "mcp command status on an empty bridge" {
  let bridge = MCPToolBridge::MCPToolBridge()
  let outcome = @posoco.CommandPort::invoke(bridge, "mcp", Json::null()) catch {
    error => fail("invoke failed: " + error.to_string())
  }
  match outcome {
    Success(feedback~, ..) =>
      inspect(feedback, content="no MCP servers configured")
    _ => fail("expected success")
  }
}
