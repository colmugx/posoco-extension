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
test "projector strips numeric constraints but keeps type and description" {
  let projected = project_tool_schema(
    wbtest_parse_schema(
      (
        #|{"type":"number","minimum":1,"maximum":10,"exclusiveMinimum":0,
        #|"multipleOf":2,"default":5,"description":"Result count"}
      ),
    ),
  )
  inspect(
    projected.stringify(),
    content="{\"type\":\"number\",\"description\":\"Result count\"}",
  )
}

///|
test "projector drops anyOf and keeps the parameter callable" {
  let projected = project_tool_schema(
    wbtest_parse_schema(
      (
        #|{"anyOf":[{"type":"string"},{"type":"null"}],
        #|"description":"Search query"}
      ),
    ),
  )
  inspect(projected.stringify(), content="{\"description\":\"Search query\"}")
}

///|
test "projector recurses into nested properties and array items" {
  let projected = project_tool_schema(
    wbtest_parse_schema(
      (
        #|{"type":"object","properties":{
        #|"numResults":{"type":"number","minimum":1,"maximum":10},
        #|"urls":{"type":"array","items":{"type":"string","minLength":1,"format":"uri"},"minItems":1,"maxItems":5}
        #|},"required":["numResults"],"additionalProperties":false,
        #|"$schema":"http://json-schema.org/draft-07/schema#"}
      ),
    ),
  )
  inspect(
    projected.stringify(),
    content=(
      #|{"type":"object","properties":{"numResults":{"type":"number"},"urls":{"type":"array","items":{"type":"string"}}},"required":["numResults"],"additionalProperties":false}
    ),
  )
}

///|
test "projector keeps supported enum, const, and boolean schemas" {
  let projected = project_tool_schema(
    wbtest_parse_schema(
      (
        #|{"type":"object","properties":{
        #|"provider":{"enum":["duckduckgo","bing"],"type":"string"},
        #|"exact":{"const":true},
        #|"never":{"not":{}}
        #|}}
      ),
    ),
  )
  inspect(
    projected.stringify(),
    content=(
      #|{"type":"object","properties":{"provider":{"enum":["duckduckgo","bing"],"type":"string"},"exact":{"const":true},"never":{}}}
    ),
  )
}

///|
test "projector never fails on unexpected shapes" {
  inspect(project_tool_schema(Json::boolean(true)).stringify(), content="true")
  inspect(project_tool_schema(Json::null()).stringify(), content="null")
  inspect(
    project_tool_schema(
      wbtest_parse_schema(
        (
          #|{"type":["string","null"],"properties":"not-an-object",
          #|"items":[1,2],"required":"text","enum":"wrong","pattern":"^a"}
        ),
      ),
    ).stringify(),
    content="{}",
  )
}

///|
test "list_tools projects the raw Pi schema before ToolDef creation" {
  let adaptor = pi_adaptor_new()
  wbtest_push_tool_schema(
    adaptor.host,
    "web_search",
    (
      #|{"type":"object","properties":{
      #|"query":{"type":"string","minLength":1,"description":"Search query"},
      #|"numResults":{"type":"number","minimum":1,"maximum":10,"default":5},
      #|"recency":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"Filter"}
      #|},"required":["query"],"additionalProperties":false}
    ),
  )
  let tools = adaptor.list_tools()
  inspect(tools.length(), content="1")
  inspect(tools[0].name.to_string(), content="web_search")
  inspect(
    tools[0].input_schema.stringify(),
    content=(
      #|{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"numResults":{"type":"number"},"recency":{"description":"Filter"}},"required":["query"],"additionalProperties":false}
    ),
  )
}

///|
test "catalog JSON endpoints expose projected parameters" {
  let adaptor = pi_adaptor_new()
  wbtest_push_tool_schema(
    adaptor.host,
    "constrained",
    (
      #|{"type":"object","properties":{"count":{"type":"integer","minimum":0,"maximum":100}},"required":["count"]}
    ),
  )
  let raw = @json.parse(js_catalog_json(adaptor.host)) catch {
    _ => Json::null()
  }
  guard raw is Json::Array(entries) else { abort("catalog must be an array") }
  let raw_params = match entries[0] {
    Json::Object(fields) =>
      match fields.get("parameters") {
        Some(value) => value
        None => Json::null()
      }
    _ => Json::null()
  }
  inspect(
    raw_params.stringify(),
    content="{\"type\":\"object\",\"properties\":{\"count\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":100}},\"required\":[\"count\"]}",
  )
  let projected = pi_adaptor_catalog_json(adaptor)
  inspect(projected.contains("\"minimum\""), content="false")
  let snapshot = pi_adaptor_catalog_snapshot_json(adaptor)
  inspect(snapshot.contains("\"minimum\""), content="false")
}
