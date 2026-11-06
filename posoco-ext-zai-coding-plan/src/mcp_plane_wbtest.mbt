///|
/// Namespacing and routing of provider-owned MCP tools. Pure functions only:
/// the network plane is exercised by construction, never by a fixture server.
test "tool names are namespaced by their provider-owned group" {
  inspect(
    zai_mcp_namespaced_tool("web_search_prime", "web_search"),
    content="web_search_prime__web_search",
  )
  inspect(
    zai_mcp_namespaced_tool("zread", "read_file"),
    content="zread__read_file",
  )
}

///|
test "a namespaced name routes back to its group and server-side tool" {
  match zai_mcp_route("web_search_prime__web_search") {
    Some(route) => {
      inspect(route.group, content="web_search_prime")
      inspect(route.tool, content="web_search")
    }
    None => fail("expected a decoded route")
  }
}

///|
test "a server-side tool name may itself contain the separator" {
  // Only the first separator is owned by the plane; the rest belongs to the
  // server's own naming and must survive the round trip.
  match zai_mcp_route("zread__search__docs") {
    Some(route) => {
      inspect(route.group, content="zread")
      inspect(route.tool, content="search__docs")
    }
    None => fail("expected a decoded route")
  }
}

///|
test "names without a usable separator are not ours" {
  inspect(zai_mcp_route("web_search") is None, content="true")
  inspect(zai_mcp_route("__web_search") is None, content="true")
  inspect(zai_mcp_route("web_search_prime__") is None, content="true")
  inspect(zai_mcp_route("") is None, content="true")
}

///|
test "tool descriptions extend the server text with priority guidance" {
  let enriched = zai_mcp_tool_description(
    "web_reader", "Fetch and Convert URL to Large Model Friendly Input.",
  )
  inspect(
    enriched.contains("Fetch and Convert URL to Large Model Friendly Input."),
    content="true",
  )
  inspect(enriched.contains("GLM Coding Plan priority tool"), content="true")
  inspect(enriched.contains("rate-limited"), content="true")
}

///|
test "an empty server description lands as guidance alone" {
  inspect(
    zai_mcp_tool_description("zread", ""),
    content=zai_coding_plan_tool_guidance("zread").unwrap(),
  )
}

///|
test "a group without guidance keeps the server description untouched" {
  inspect(zai_mcp_tool_description("soon", "raw"), content="raw")
  inspect(zai_mcp_tool_description("soon", ""), content="")
}
