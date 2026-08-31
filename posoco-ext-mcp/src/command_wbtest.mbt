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
test "format_mcp_status renders connected failed and pending rows" {
  let rows : Array[McpStatusRow] = [
    { name: "github", state: Connected(45), },
    { name: "context7", state: Failed("MCP connect failed for 'context7'"), },
    { name: "exa", state: Pending, },
  ]
  inspect(
    format_mcp_status(LoadMode::Lazy, rows),
    content=(
      #|3 servers: 1 connected, 1 failed, 1 pending
      #|- github: connected, 45 tools
      #|- context7: failed — MCP connect failed for 'context7'
      #|- exa: pending (connects on first turn)
    ),
  )
}

///|
test "format_mcp_status singular server and tool counts" {
  let rows : Array[McpStatusRow] = [{ name: "exa", state: Connected(1), }]
  inspect(
    format_mcp_status(LoadMode::Eager, rows),
    content=(
      #|1 server: 1 connected, 0 failed, 0 pending
      #|- exa: connected, 1 tool
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
test "mcp_status_json carries per-server state" {
  let rows : Array[McpStatusRow] = [
    { name: "github", state: Connected(2), },
    { name: "exa", state: Failed("MCP connect failed for 'exa'"), },
  ]
  inspect(
    mcp_status_json(LoadMode::Lazy, rows).stringify(),
    content="{\"kind\":\"mcp_status\",\"mode\":\"lazy\",\"servers\":[{\"name\":\"github\",\"status\":\"connected\",\"tools\":2},{\"name\":\"exa\",\"status\":\"failed\",\"reason\":\"MCP connect failed for 'exa'\"}]}",
  )
}

///|
test "status_rows maps failures and pending before activation" {
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
