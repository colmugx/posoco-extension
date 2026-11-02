///|
/// Register through the real api.registerTool path (not state.tools) so the
/// bumpCatalog/onCatalogChange chain under test is exercised. Empty label
/// omits the field; execute is a placeholder — these tools are never run.
extern "js" fn wbtest_api_register_tool(
  host : JsPiHost,
  name : String,
  label : String,
  description : String,
  schema_json : String,
) -> Unit =
  #| (host, name, label, description, schemaJson) => {
  #|   host.api.registerTool({
  #|     name,
  #|     ...(label === "" ? {} : { label }),
  #|     description,
  #|     parameters: JSON.parse(schemaJson),
  #|     execute: async () => ({ content: [{ type: "text", text: "ok" }] }),
  #|   });
  #| }

///|
/// Register a tool that also advertises a promptSnippet, used to prove the
/// prompt-block serializer honors the active set.
extern "js" fn wbtest_api_register_tool_with_snippet(
  host : JsPiHost,
  name : String,
  snippet : String,
) -> Unit =
  #| (host, name, snippet) => {
  #|   host.api.registerTool({
  #|     name,
  #|     description: name,
  #|     promptSnippet: snippet,
  #|     parameters: { type: "object", properties: {} },
  #|     execute: async () => ({ content: [{ type: "text", text: "ok" }] }),
  #|   });
  #| }

///|
extern "js" fn wbtest_api_set_active_tools(
  host : JsPiHost,
  names_json : String,
) -> Unit =
  #| (host, namesJson) => { host.api.setActiveTools(JSON.parse(namesJson)) }

///|
extern "js" fn wbtest_api_active_tools_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.api.getActiveTools())

///|
extern "js" fn wbtest_api_all_tools_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.api.getAllTools())

///|
extern "js" fn wbtest_catalog_version(host : JsPiHost) -> Int32 =
  #| (host) => host.state.catalogVersion

///|
test "active set defaults to every registered tool" {
  let adaptor = pi_adaptor_new()
  wbtest_api_register_tool(
    adaptor.host,
    "alpha",
    "",
    "Alpha tool.",
    "{\"type\":\"object\",\"properties\":{}}",
  )
  wbtest_api_register_tool(
    adaptor.host,
    "beta",
    "Beta label",
    "Beta tool.",
    "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}}}",
  )
  inspect(js_tool_count(adaptor.host), content="2")
  inspect(
    wbtest_api_active_tools_json(adaptor.host),
    content="[\"alpha\",\"beta\"]",
  )
  // getAllTools projects the full registry with label fallback and ignores
  // the active set entirely.
  inspect(
    wbtest_api_all_tools_json(adaptor.host),
    content="[{\"name\":\"alpha\",\"label\":\"alpha\",\"description\":\"Alpha tool.\"},{\"name\":\"beta\",\"label\":\"Beta label\",\"description\":\"Beta tool.\"}]",
  )
}

///|
test "setActiveTools shrink keeps every catalog accessor in lockstep" {
  let adaptor = pi_adaptor_new()
  wbtest_api_register_tool(
    adaptor.host,
    "alpha",
    "",
    "Alpha tool.",
    "{\"type\":\"object\",\"properties\":{}}",
  )
  wbtest_api_register_tool(
    adaptor.host,
    "beta",
    "",
    "Beta tool.",
    "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}}}",
  )
  let version_before = wbtest_catalog_version(adaptor.host)
  wbtest_api_set_active_tools(adaptor.host, "[\"beta\"]")
  inspect(wbtest_catalog_version(adaptor.host) > version_before, content="true")
  inspect(js_tool_count(adaptor.host), content="1")
  // Every index-based reader now describes beta; out-of-range reads stay
  // empty instead of slipping into the deactivated tool.
  inspect(js_tool_name(adaptor.host, 0), content="beta")
  inspect(js_tool_name(adaptor.host, 1), content="")
  inspect(js_tool_description(adaptor.host, 0), content="Beta tool.")
  inspect(js_tool_description(adaptor.host, 1), content="")
  inspect(
    js_tool_schema_json(adaptor.host, 0),
    content="{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}}}",
  )
  // The registry keeps both entries for getAllTools; the catalog JSON views
  // shrink to the active set.
  inspect(
    wbtest_api_all_tools_json(adaptor.host).contains("\"alpha\""),
    content="true",
  )
  let catalog = parse_json_or_null(js_catalog_json(adaptor.host))
  guard catalog is Json::Array(entries) else { abort("catalog must be an array") }
  inspect(entries.length(), content="1")
  let tool = match entries[0] {
    Json::Object(tool_fields) => tool_fields
    _ => abort("catalog entry must be an object")
  }
  let name = match tool.get("name") {
    Some(Json::String(value)) => value
    _ => abort("catalog entry must carry a name")
  }
  inspect(name, content="beta")
  let snapshot = parse_json_or_null(js_catalog_snapshot_json(adaptor.host))
  guard snapshot is Json::Object(fields) else { abort("snapshot must be an object") }
  guard fields.get("tools") is Some(Json::Array(items)) else {
    abort("missing snapshot tools")
  }
  inspect(items.length(), content="1")
}

///|
test "inactive tools contribute no prompt snippet" {
  let adaptor = pi_adaptor_new()
  wbtest_api_register_tool_with_snippet(adaptor.host, "alpha", "Use alpha.")
  wbtest_api_register_tool_with_snippet(adaptor.host, "beta", "Use beta.")
  inspect(js_prompt_snippets_json(adaptor.host).contains("Use beta."), content="true")
  wbtest_api_set_active_tools(adaptor.host, "[\"alpha\"]")
  let snippets = js_prompt_snippets_json(adaptor.host)
  inspect(snippets.contains("Use alpha."), content="true")
  // A deactivated tool must not advertise itself in the prompt block.
  inspect(snippets.contains("Use beta."), content="false")
}

///|
test "setActiveTools ignores unregistered names like pi" {
  let adaptor = pi_adaptor_new()
  wbtest_api_register_tool(
    adaptor.host,
    "alpha",
    "",
    "Alpha tool.",
    "{\"type\":\"object\",\"properties\":{}}",
  )
  wbtest_api_register_tool(
    adaptor.host,
    "beta",
    "",
    "Beta tool.",
    "{\"type\":\"object\",\"properties\":{}}",
  )
  // pi.setActiveToolsByName silently drops names outside the registry.
  wbtest_api_set_active_tools(adaptor.host, "[\"beta\",\"ghost\"]")
  inspect(wbtest_api_active_tools_json(adaptor.host), content="[\"beta\"]")
  // An all-unknown list deactivates everything, exactly like pi filtering the
  // requested names against the registry.
  wbtest_api_set_active_tools(adaptor.host, "[\"ghost\"]")
  inspect(js_tool_count(adaptor.host), content="0")
  inspect(wbtest_api_active_tools_json(adaptor.host), content="[]")
  // Re-expanding by name restores visibility; the registry never lost a tool.
  wbtest_api_set_active_tools(adaptor.host, "[\"alpha\",\"beta\"]")
  inspect(js_tool_count(adaptor.host), content="2")
  inspect(
    wbtest_api_active_tools_json(adaptor.host),
    content="[\"alpha\",\"beta\"]",
  )
}

///|
test "tools registered after setActiveTools join the active set like pi" {
  let adaptor = pi_adaptor_new()
  wbtest_api_register_tool(
    adaptor.host,
    "alpha",
    "",
    "Alpha tool.",
    "{\"type\":\"object\",\"properties\":{}}",
  )
  wbtest_api_register_tool(
    adaptor.host,
    "beta",
    "",
    "Beta tool.",
    "{\"type\":\"object\",\"properties\":{}}",
  )
  wbtest_api_set_active_tools(adaptor.host, "[\"alpha\"]")
  inspect(js_tool_count(adaptor.host), content="1")
  // pi's _refreshToolRegistry appends new registry names to the active set,
  // so a late registration becomes visible without re-listing every name.
  wbtest_api_register_tool(
    adaptor.host,
    "late",
    "",
    "Late tool.",
    "{\"type\":\"object\",\"properties\":{}}",
  )
  inspect(js_tool_count(adaptor.host), content="2")
  inspect(
    wbtest_api_active_tools_json(adaptor.host),
    content="[\"alpha\",\"late\"]",
  )
}

///|
async test "registerTool and setActiveTools bump the catalog and flip dirty" {
  let adaptor = pi_adaptor_new()
  inspect(adaptor.catalog_dirty, content="true")
  adaptor.catalog_dirty = false
  let version_before = wbtest_catalog_version(adaptor.host)
  wbtest_api_register_tool(
    adaptor.host,
    "solo",
    "",
    "Solo tool.",
    "{\"type\":\"object\",\"properties\":{}}",
  )
  inspect(adaptor.catalog_dirty, content="true")
  inspect(wbtest_catalog_version(adaptor.host) > version_before, content="true")
  adaptor.catalog_dirty = false
  let version_after_register = wbtest_catalog_version(adaptor.host)
  wbtest_api_set_active_tools(adaptor.host, "[\"solo\"]")
  inspect(adaptor.catalog_dirty, content="true")
  inspect(
    wbtest_catalog_version(adaptor.host) > version_after_register,
    content="true",
  )
  // Republishing consumes the flag (no contribution handle in this test, but
  // the dirty state still clears for the next model call).
  pi_adaptor_publish(adaptor)
  inspect(adaptor.catalog_dirty, content="false")
}
