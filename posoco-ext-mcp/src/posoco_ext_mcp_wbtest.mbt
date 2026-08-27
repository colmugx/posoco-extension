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
    cached_schema_json: "",
    icon: None,
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
    cached_schema_json: "",
    icon: None,
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
    CatalogEntry::{ connection_index: 0, tools: [left] },
    CatalogEntry::{ connection_index: 1, tools: [right] },
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
