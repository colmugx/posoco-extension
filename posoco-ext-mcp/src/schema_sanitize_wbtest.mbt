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
