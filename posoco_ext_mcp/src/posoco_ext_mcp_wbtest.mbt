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
  assert_eq(posoco_def.name, "filesystem__search")
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
async test "list_tools_returns_empty_before_connect" {
  let bridge = MCPToolBridge::new()
  let tools = bridge.list_tools()
  assert_true(tools.is_empty())
}

///|
async test "close_clears_state" {
  let bridge = MCPToolBridge::new()
  bridge.close()
  let tools = bridge.list_tools()
  assert_true(tools.is_empty())
}
