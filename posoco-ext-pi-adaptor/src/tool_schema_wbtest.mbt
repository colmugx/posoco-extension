///|
/// Whitebox helper: register a tool with an arbitrary raw parameters schema,
/// bypassing api.registerTool normalization, so tests can feed schemas that
/// mirror real TypeBox output.
extern "js" fn wbtest_push_tool_schema(
  host : JsPiHost,
  name : String,
  schema_json : String,
) -> Unit =
  #| (host, name, schemaJson) => {
  #|   const tool = { name, description: "wbtest", parameters: JSON.parse(schemaJson) };
  #|   host.state.tools.push(tool);
  #|   host.state.byName.set(name, tool);
  #|   host.state.catalogVersion += 1;
  #| }

///|
fn wbtest_parse_schema(schema_json : String) -> Json {
  @json.parse(schema_json) catch {
    _ => Json::null()
  }
}

///|
test "Pi tool schema is handed to Posoco without lossy conversion" {
  let adaptor = pi_adaptor_new()
  let schema =
    #|{"type":"object","properties":{
    #|"count":{"type":"integer","minimum":0,"maximum":100},
    #|"mode":{"anyOf":[{"type":"string"},{"type":"null"}]},
    #|"pattern":{"type":"string","pattern":"^pi-"}
    #|},"required":["count"],"additionalProperties":false}
  wbtest_push_tool_schema(adaptor.host, "constrained", schema)
  let tools = adaptor.list_tools()
  inspect(tools.length(), content="1")
  inspect(tools[0].input_schema == wbtest_parse_schema(schema), content="true")
  let catalog = parse_json_or_null(pi_adaptor_catalog_json(adaptor))
  guard catalog is Json::Array(entries) else {
    abort("catalog must be an array")
  }
  guard entries[0] is Json::Object(fields) else {
    abort("catalog entry must be an object")
  }
  inspect(fields["parameters"] == tools[0].input_schema, content="true")
  let snapshot = parse_json_or_null(pi_adaptor_catalog_snapshot_json(adaptor))
  guard snapshot is Json::Object(snapshot_fields) else {
    abort("missing snapshot")
  }
  guard snapshot_fields["tools"] is Json::Array(snapshot_items) else {
    abort("missing tools")
  }
  guard snapshot_items[0] is Json::Object(item) else {
    abort("missing tool entry")
  }
  inspect(item["parameters"] == tools[0].input_schema, content="true")
}

///|
test "boolean and invalid schemas are not silently rewritten" {
  let adaptor = pi_adaptor_new()
  wbtest_push_tool_schema(adaptor.host, "always_reject", "false")
  wbtest_push_tool_schema(
    adaptor.host,
    "malformed",
    (
      #|{"type":["string","null"],"required":"not an array"}
    ),
  )
  let tools = adaptor.list_tools()
  inspect(tools.length(), content="2")
  inspect(tools[0].input_schema == Json::boolean(false), content="true")
  inspect(
    tools[1].input_schema ==
    wbtest_parse_schema(
      (
        #|{"type":["string","null"],"required":"not an array"}
      ),
    ),
    content="true",
  )
}
