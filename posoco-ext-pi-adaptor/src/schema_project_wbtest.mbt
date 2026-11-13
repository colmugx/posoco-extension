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
test "projector preserves numeric constraints, defaults, and unions" {
  let schema = wbtest_parse_schema(
    (
      #|{"type":"object","properties":{
      #|"count":{"type":"integer","minimum":1,"maximum":10,"default":5},
      #|"query":{"anyOf":[{"type":"string","minLength":1},{"type":"null"}]}
      #|},"required":["query"],"additionalProperties":false}
    ),
  )
  inspect(project_tool_schema(schema) == schema, content="true")
}

///|
test "projector retains boolean and unfamiliar schemas without weakening" {
  inspect(project_tool_schema(Json::boolean(false)).stringify(), content="false")
  let schema = wbtest_parse_schema(
    (
      #|{"$schema":"https://json-schema.org/draft/2020-12/schema",
      #|"$defs":{"tag":{"type":"string","pattern":"^pi-"}},
      #|"allOf":[{"$ref":"#/$defs/tag"}],"unevaluatedProperties":false}
    ),
  )
  inspect(project_tool_schema(schema) == schema, content="true")
}

///|
test "ToolProvider and catalog expose identical Pi schema" {
  let adaptor = pi_adaptor_new()
  let schema = (
    #|{"type":"object","properties":{
    #|"count":{"type":"integer","minimum":0,"maximum":100},
    #|"mode":{"anyOf":[{"type":"string"},{"type":"null"}]}
    #|},"required":["count"]}
  )
  wbtest_push_tool_schema(adaptor.host, "constrained", schema)
  let tools = adaptor.list_tools()
  inspect(tools.length(), content="1")
  inspect(tools[0].input_schema == wbtest_parse_schema(schema), content="true")
  let catalog = parse_json_or_null(pi_adaptor_catalog_json(adaptor))
  guard catalog is Json::Array(entries) else { abort("catalog must be an array") }
  guard entries[0] is Json::Object(fields) else { abort("catalog entry must be an object") }
  inspect(fields["parameters"] == tools[0].input_schema, content="true")
  let snapshot = parse_json_or_null(pi_adaptor_catalog_snapshot_json(adaptor))
  guard snapshot is Json::Object(snapshot_fields) else { abort("missing snapshot") }
  guard snapshot_fields["tools"] is Json::Array(snapshot_items) else { abort("missing tools") }
  guard snapshot_items[0] is Json::Object(item) else { abort("missing tool entry") }
  inspect(item["parameters"] == tools[0].input_schema, content="true")
}
