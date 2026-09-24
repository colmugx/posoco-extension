///|
test "sanitize keeps the kernel subset and drops the rest" {
  let raw =
    #|{
    #|  "type": "object",
    #|  "properties": {
    #|    "q": { "anyOf": [{ "type": "string" }], "minLength": 1, "description": "query" },
    #|    "n": { "type": "integer", "minimum": 0 },
    #|    "tags": { "type": "array", "items": { "type": "string", "pattern": "^[a-z]+$" } }
    #|  },
    #|  "required": ["q"],
    #|  "additionalProperties": false,
    #|  "$defs": { "x": { "type": "string" } },
    #|  "minimum": 5
    #|}
    #|
  let dirty : Json = @json.parse(raw) catch {
    _ => fail("fixture json must parse")
  }
  let clean = sanitize_tool_schema(dirty)
  json_inspect(clean, content={
    "type": "object",
    "properties": {
      "q": { "description": "query" },
      "n": { "type": "integer" },
      "tags": { "type": "array", "items": { "type": "string" } },
    },
    "required": ["q"],
    "additionalProperties": false,
  })
}

///|
test "sanitize rewrites schema false to true and passes booleans through" {
  inspect(
    sanitize_tool_schema(Json::boolean(false)) == Json::boolean(true),
    content="true",
  )
  inspect(
    sanitize_tool_schema(Json::boolean(true)) == Json::boolean(true),
    content="true",
  )
  // A non-object, non-boolean schema node is not in the subset; it degrades
  // to unconstrained rather than poisoning the catalog.
  inspect(
    sanitize_tool_schema(Json::null()) == Json::boolean(true),
    content="true",
  )
}

///|
test "sanitize caps documentation but preserves validation fields" {
  let long_desc = "d".repeat(MCP_SCHEMA_DESCRIPTION_CHARS + 100)
  let long_title = "t".repeat(MCP_SCHEMA_TITLE_CHARS + 100)
  let dirty = Json::object({
    "type": Json::string("string"),
    "description": Json::string(long_desc),
    "title": Json::string(long_title),
    "enum": Json::array([Json::string("a"), Json::string("b")]),
    "const": Json::string("a"),
    "default": Json::string("a"),
    "examples": Json::array([Json::string("very large example")]),
  })
  guard sanitize_tool_schema(dirty) is Json::Object(clean) else {
    fail("expected object schema")
  }
  guard clean.get("description") is Some(Json::String(desc)) else {
    fail("expected description")
  }
  guard clean.get("title") is Some(Json::String(title)) else {
    fail("expected title")
  }
  assert_true(desc.has_suffix("…"))
  assert_true(title.has_suffix("…"))
  assert_true(desc.length() < long_desc.length())
  assert_true(title.length() < long_title.length())
  assert_true(clean.get("enum") is Some(Json::Array(_)))
  assert_true(clean.get("const") is Some(Json::String("a")))
  assert_true(clean.get("default") is Some(Json::String("a")))
  assert_true(clean.get("examples") is None)
}
