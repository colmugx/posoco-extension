///|
/// Whitebox tests for internal helpers and type conversions.

///|
test "namespaced_tool_name_double_underscore" {
  let name = namespaced_tool_name("github", "create_issue")
  assert_eq(name, "github__create_issue")
}

///|
test "namespaced_tool_name_simple" {
  let name = namespaced_tool_name("fs", "read")
  assert_eq(name, "fs__read")
}

///|
test "strip_namespace_roundtrip" {
  let original = "create_issue"
  let ns = namespaced_tool_name("github", original)
  let stripped = strip_namespace(ns, "github")
  assert_eq(stripped, original)
}

///|
test "strip_namespace_no_prefix_returns_original" {
  let stripped = strip_namespace("some_tool", "github")
  assert_eq(stripped, "some_tool")
}

///|
test "strip_namespace_empty_server" {
  let name = namespaced_tool_name("", "tool")
  assert_eq(name, "__tool")
  let stripped = strip_namespace("__tool", "")
  assert_eq(stripped, "tool")
}

///|
test "convert_tool_def_namespaces_and_preserves_fields" {
  let mcp_def = @types.ToolDefinition::{
    name: "search",
    description: "Search for items",
    input_schema: Json::object(
      Map::from_array([("query", Json::string("string"))]),
    ),
  }
  let posoco_def = convert_tool_def(mcp_def, "filesystem")
  assert_eq(posoco_def.name.to_string(), "filesystem__search")
  assert_eq(posoco_def.description, "Search for items")
  assert_true(posoco_def.input_schema is Json::Object(_))
}

///|
test "convert_content_to_string_text_only" {
  let items = [
    @types.ContentItem::Text("hello"),
    @types.ContentItem::Text("world"),
  ]
  let result = convert_content_to_string(items)
  assert_eq(result, "hello\nworld")
}

///|
test "convert_content_to_string_single_text" {
  let items = [@types.ContentItem::Text("hello")]
  let result = convert_content_to_string(items)
  assert_eq(result, "hello")
}

///|
test "convert_content_to_string_empty" {
  let items : Array[@types.ContentItem] = []
  let result = convert_content_to_string(items)
  assert_eq(result, "")
}

///|
test "convert_content_to_string_resource_link" {
  let items = [@types.ContentItem::ResourceLink("file:///config.json")]
  let result = convert_content_to_string(items)
  assert_eq(result, "[Resource: file:///config.json]")
}

///|
fn catalog_test_tool(name : String) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(name),
    description: "test tool",
    input_schema: Json::object(Map::from_array([])),
    owner: @posoco.OwnerId::unchecked("posoco_ext_mcp"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("mcp-test"),
  }
}

///|
fn catalog_test_mcp_tool(name : String) -> @types.ToolDefinition {
  @types.ToolDefinition::{
    name,
    description: "test tool",
    input_schema: Json::object(Map::from_array([])),
  }
}

///|
test "catalog_plan_builds_complete_reverse_map" {
  let entries = [
    CatalogEntry::{
      connection_index: 0,
      tools: [catalog_test_tool("files__read")],
    },
    CatalogEntry::{
      connection_index: 1,
      tools: [catalog_test_tool("github__issue")],
    },
  ]
  match plan_catalog(entries, 2) {
    Ok(plan) => {
      assert_eq(plan.entries.length(), 2)
      assert_true(plan.tool_to_conn.get("files__read") is Some(0))
      assert_true(plan.tool_to_conn.get("github__issue") is Some(1))
    }
    Err(message) => fail("unexpected catalog error: " + message)
  }
}

///|
test "catalog_collision_does_not_mutate_previous_snapshot" {
  let previous_tools = [catalog_test_tool("legacy__read")]
  let previous_route : Map[String, Int] = Map::from_array([("legacy__read", 0)])
  let ambiguous_name = "alpha__beta__gamma"
  let left = convert_tool_def(catalog_test_mcp_tool("beta__gamma"), "alpha")
  let right = convert_tool_def(catalog_test_mcp_tool("gamma"), "alpha__beta")
  assert_eq(left.name.to_string(), ambiguous_name)
  assert_eq(right.name.to_string(), ambiguous_name)
  let candidate = [
    CatalogEntry::{ connection_index: 0, tools: [left], },
    CatalogEntry::{ connection_index: 1, tools: [right], },
  ]
  let commits : Array[Unit] = []
  match replace_catalog(candidate, 2, _plan => commits.push(())) {
    Err(message) => assert_true(message.contains("collision"))
    Ok(_) => fail("expected namespaced collision")
  }
  // The production transaction helper never invokes commit for a failed plan,
  // leaving the known-good snapshot available unchanged.
  assert_eq(commits.length(), 0)
  assert_eq(previous_tools.length(), 1)
  assert_eq(previous_tools[0].name.to_string(), "legacy__read")
  assert_true(previous_route.get("legacy__read") is Some(0))
  assert_true(previous_route.get(ambiguous_name) is None)
}

///|
test "catalog_plan_rejects_incomplete_refresh" {
  let candidate = [
    CatalogEntry::{
      connection_index: 0,
      tools: [catalog_test_tool("files__read")],
    },
  ]
  match plan_catalog(candidate, 2) {
    Err(message) => assert_true(message.contains("incomplete"))
    Ok(_) => fail("expected incomplete catalog failure")
  }
}

///|
test "refresh_fetch_failure_preserves_previous_catalog" {
  let previous_tools = [catalog_test_tool("legacy__read")]
  let previous_route : Map[String, Int] = Map::from_array([("legacy__read", 0)])
  let fetches : Array[Result[CatalogEntry, String]] = [
    Ok(CatalogEntry::{
      connection_index: 0,
      tools: [catalog_test_tool("fresh__read")],
    }),
    Err("MCP refresh list_tools failed for 'private-server'"),
  ]
  let commits : Array[Unit] = []
  match replace_catalog_from_fetches(fetches, 2, _plan => commits.push(())) {
    Err(message) => assert_true(message.contains("refresh list_tools failed"))
    Ok(_) => fail("expected injected refresh fetch failure")
  }
  assert_eq(commits.length(), 0)
  assert_eq(previous_tools.length(), 1)
  assert_eq(previous_tools[0].name.to_string(), "legacy__read")
  assert_true(previous_route.get("legacy__read") is Some(0))
  assert_true(previous_route.get("fresh__read") is None)
}

///|
test "mcp_call_failures_are_typed_and_redacted" {
  let raw_tool = "tool\nsecret\t" + "x".repeat(200) + "TAIL_SECRET"
  for failure in [TransportFailure, RemoteFailure] {
    match mcp_call_failure(failure, raw_tool) {
      @posoco.RuntimeError::InvocationFailed(message) => {
        assert_true(message.contains("MCP call failed"))
        assert_true(message.contains("stage="))
        assert_false(message.contains("\n"))
        assert_false(message.contains("\t"))
        assert_false(message.contains("TAIL_SECRET"))
      }
      _ => fail("expected typed MCP call failure")
    }
  }
}

///|
test "sanitize_label_is_single_line_and_bounded" {
  let label = @devkit.sanitize_label("server\nsecret\t" + "x".repeat(200))
  assert_false(label.contains("\n"))
  assert_false(label.contains("\t"))
  assert_true(label.length() < 140)
}

///|
async test "list_tools_returns_empty_before_connect" {
  let bridge = MCPToolBridge()
  let tools = @posoco.ToolProvider::list_tools(bridge)
  assert_true(tools.is_empty())
}

///|
async test "close_clears_state" {
  let bridge = MCPToolBridge()
  bridge.close()
  let tools = @posoco.ToolProvider::list_tools(bridge)
  assert_true(tools.is_empty())
}

///|
fn tuning_test_transport() -> @transport.AnyTransport {
  @transport.AnyTransport::StdioClient(
    @transport.StdioClientTransport::StdioClientTransport(
      cmd="echo",
      args=[],
      extra_env=Map::from_array([]),
    ),
  )
}

///|
test "server_config_constructor_applies_resilience_defaults" {
  let config = MCPServerConfig::MCPServerConfig(
    name="srv",
    transport=tuning_test_transport(),
    auth=ServerAuth::NoAuth,
  )
  assert_eq(config.timeout_ms, 30_000)
  assert_eq(config.max_reconnects, 1)
  let tuned = MCPServerConfig::MCPServerConfig(
    name="srv",
    transport=tuning_test_transport(),
    auth=ServerAuth::NoAuth,
    timeout_ms=250,
    max_reconnects=0,
  )
  assert_eq(tuned.timeout_ms, 250)
  assert_eq(tuned.max_reconnects, 0)
}

///|
test "mcp_call_failure_timeout_stage_carries_deadline" {
  match mcp_call_failure(MCPCallFailure::TimedOut(1234), "tool") {
    @posoco.RuntimeError::InvocationFailed(message) => {
      assert_true(message.contains("MCP call failed"))
      assert_true(message.contains("stage=timeout"))
      assert_true(message.contains("timeout_ms=1234"))
      assert_false(message.contains("\n"))
    }
    _ => fail("expected typed MCP timeout failure")
  }
}

///|
test "connection_level_errors_are_distinguished_from_remote_errors" {
  let connection_level : Array[@types.MCPError] = [
    @types.InternalError("Send failed: broken pipe"),
    @types.InternalError("Receive failed: eof"),
    @types.InternalError("Connection closed"),
    @types.InternalError("Response timeout"),
    @types.TransportError(
      @types.InvalidState("Cannot send on closed transport"),
    ),
    @types.TransportError(@types.ConnectionClosed),
  ]
  for e in connection_level {
    assert_true(is_connection_level_error(e))
  }
  let remote : Array[@types.MCPError] = [
    @types.InternalError("Server error: tool exploded"),
    @types.ParseError("Invalid JSON response"),
    @types.InvalidRequest("Response missing 'result' field"),
    @types.ToolError("business failure"),
  ]
  for e in remote {
    assert_false(is_connection_level_error(e))
  }
}

///|
test "list_tools_failure_message_distinguishes_timeout" {
  let timeout = list_tools_failure_message(
    "MCP list_tools failed",
    "srv",
    ListToolsFailure::TimedOut(2500),
  )
  assert_eq(
    timeout, "MCP list_tools failed for 'srv' (stage=timeout, timeout_ms=2500)",
  )
  let plain = list_tools_failure_message(
    "MCP list_tools failed",
    "srv",
    ListToolsFailure::Failed,
  )
  assert_eq(plain, "MCP list_tools failed for 'srv'")
}

///|
/// Validates the classification assumption behind the timeout wrappers: the
/// with_timeout abort makes the wrapped call see the sticky cancel flag,
/// while the enclosing catch sees the sentinel error — not a cancellation
/// error — so a fired deadline can be classified without swallowing real
/// ambient cancellation.
async test "timeout_aborts_inner_but_outer_sees_sentinel_not_cancel" {
  let inner_flags : Array[Bool] = []
  let outer_flags : Array[Bool] = []
  let escaped_is_cancel = @async.with_timeout(30, async fn() {
    errdefer inner_flags.push(@async.is_being_cancelled())
    @async.sleep(60_000)
    true
  }) catch {
    error => {
      outer_flags.push(@async.is_being_cancelled())
      @async.is_cancellation_error(error)
    }
  }
  assert_eq(inner_flags.length(), 1)
  assert_true(inner_flags[0])
  assert_eq(outer_flags.length(), 1)
  assert_false(outer_flags[0])
  assert_false(escaped_is_cancel)
}

///|
async test "reconnect_one_rejects_missing_connection" {
  let bridge = MCPToolBridge()
  match bridge.reconnect_one(0) {
    Err(message) => assert_true(message.contains("no longer present"))
    Ok(_) => fail("expected missing connection rejection")
  }
}

///|
async test "refresh_tools_on_empty_bridge_bumps_revision" {
  let bridge = MCPToolBridge()
  match bridge.refresh_tools() {
    Ok(_) => assert_eq(bridge.catalog_revision, 1)
    Err(message) => fail("unexpected refresh error: " + message)
  }
}

///|
/// Parse-test surface over `http_connect_params` (url slice).
fn http_url(t : @transport.HttpClientTransport) -> String {
  let (url, _, _) = http_connect_params(t)
  url
}

///|
/// Parse-test surface over `http_connect_params` (token slice).
fn http_auth_token(t : @transport.HttpClientTransport) -> String {
  let (_, token, _) = http_connect_params(t)
  token
}

///|
fn http_params_test_transport(
  auth_token? : String = "",
  extra_headers? : Array[(String, String)] = [],
) -> @transport.AnyTransport {
  @transport.AnyTransport::HttpClient(
    @transport.HttpClientTransport::HttpClientTransport(
      "http://127.0.0.1:8001/mcp",
      auth_token~,
      extra_headers~,
    ),
  )
}

///|
test "http_connect_params_extracts_url_token_and_headers" {
  match http_params_test_transport(auth_token="k-1") {
    @transport.AnyTransport::HttpClient(t) => {
      let (url, token, extra_headers) = http_connect_params(t)
      assert_eq(url, "http://127.0.0.1:8001/mcp")
      assert_eq(token, "k-1")
      assert_eq(extra_headers, [])
    }
    _ => fail("expected http transport")
  }
  // No auth_token and no headers → empty token, empty header list.
  match http_params_test_transport() {
    @transport.AnyTransport::HttpClient(t) => {
      let (url, token, extra_headers) = http_connect_params(t)
      assert_eq(url, "http://127.0.0.1:8001/mcp")
      assert_eq(token, "")
      assert_eq(extra_headers, [])
    }
    _ => fail("expected http transport")
  }
}

///|
test "http_connect_params_preserves_injected_header_order" {
  // lody-scoped context headers must reach connect_http in injection order:
  // the transport array is passed through by reference, not re-sorted or
  // rebuilt.
  let headers = [
    ("x-lody-mcp-session", "s-1"),
    ("x-lody-mcp-workspace", "w-2"),
    ("x-lody-mcp-agent", "a-3"),
    ("x-lody-mcp-turn", "t-4"),
    ("x-lody-mcp-trace", "r-5"),
  ]
  match http_params_test_transport(extra_headers=headers) {
    @transport.AnyTransport::HttpClient(t) => {
      let (url, token, extra_headers) = http_connect_params(t)
      assert_eq(url, "http://127.0.0.1:8001/mcp")
      assert_eq(token, "")
      assert_eq(extra_headers.length(), 5)
      assert_eq(extra_headers[0], ("x-lody-mcp-session", "s-1"))
      assert_eq(extra_headers[1], ("x-lody-mcp-workspace", "w-2"))
      assert_eq(extra_headers[2], ("x-lody-mcp-agent", "a-3"))
      assert_eq(extra_headers[3], ("x-lody-mcp-turn", "t-4"))
      assert_eq(extra_headers[4], ("x-lody-mcp-trace", "r-5"))
    }
    _ => fail("expected http transport")
  }
}
