///|
fn raise_test_stdio_config(name : String) -> MCPServerConfig {
  MCPServerConfig::MCPServerConfig(
    name~,
    transport=@transport.AnyTransport::StdioClient(
      @transport.StdioClientTransport::StdioClientTransport(
        cmd="definitely-missing-connect-cmd",
        args=[],
        extra_env=Map::from_array([]),
      ),
    ),
    auth=ServerAuth::NoAuth,
  )
}

///|
fn raise_test_http_config(name : String) -> MCPServerConfig {
  MCPServerConfig::MCPServerConfig(
    name~,
    transport=@transport.AnyTransport::HttpClient(
      @transport.HttpClientTransport::HttpClientTransport(
        "http://127.0.0.1:1/mcp",
        auth_token="",
        extra_headers=[],
      ),
    ),
    auth=ServerAuth::NoAuth,
  )
}

///|
fn raise_test_bridge(config : MCPServerConfig) -> MCPToolBridge {
  MCPToolBridge::{
    connections: [],
    tool_to_conn: Map::from_array([]),
    mode: LoadMode::Eager,
    pending: [],
    group: None,
    activated: true,
    catalog_revision: 0,
    closing: false,
    contributions: None,
    reserved_names: [],
    published_names: [],
    startup_failures: [],
    server_tokens: Map::from_array([]),
    auth_challenges: Map::from_array([]),
    configs: Map::from_array([(config.name, config)]),
  }
}

///|
async test "connect_stdio_missing_command_fails_handshake_as_data" {
  @async.with_task_group(group => {
    let config = raise_test_stdio_config("gone")
    let bridge = raise_test_bridge(config)
    match bridge.connect(config, group) {
      Err(message) => {
        assert_true(message.contains("'gone'"))
        assert_true(message.contains("stage=handshake"))
      }
      Ok(_) => fail("a missing command must fail the handshake")
    }
    assert_eq(bridge.catalog_revision, 0)
    assert_true(bridge.connections.is_empty())
    assert_true(bridge.auth_challenge("gone") is None)
  })
}

///|
async test "connect_http_refused_endpoint_fails_handshake_as_data" {
  @async.with_task_group(group => {
    let config = raise_test_http_config("dead")
    let bridge = raise_test_bridge(config)
    match bridge.connect(config, group) {
      Err(message) => {
        assert_true(message.contains("'dead'"))
        assert_true(message.contains("stage=handshake"))
      }
      Ok(_) => fail("a closed loopback port must fail the handshake")
    }
    assert_eq(bridge.catalog_revision, 0)
    assert_true(bridge.connections.is_empty())
    assert_true(bridge.auth_challenge("dead") is None)
  })
}
