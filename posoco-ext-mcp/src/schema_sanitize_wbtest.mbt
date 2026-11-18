///|
test "sanitize keeps the 2020-12 constraints the kernel enforces" {
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
  // Posoco 0.23.0 compiles full 2020-12, so every argument-shaping keyword
  // must survive the boundary: dropping `anyOf`/`minLength`/`minimum`/
  // `pattern` here is what made the model guess at a third-party schema.
  json_inspect(clean, content={
    "type": "object",
    "properties": {
      "q": {
        "anyOf": [{ "type": "string" }],
        "minLength": 1,
        "description": "query",
      },
      "n": { "type": "integer", "minimum": 0 },
      "tags": {
        "type": "array",
        "items": { "type": "string", "pattern": "^[a-z]+$" },
      },
    },
    "required": ["q"],
    "additionalProperties": false,
    "$defs": { "x": { "type": "string" } },
    "minimum": 5,
  })
}

///|
test "sanitize keeps local refs and loosens the ones it cannot resolve" {
  let raw =
    #|{
    #|  "type": "object",
    #|  "properties": {
    #|    "local": { "$ref": "#/$defs/item" },
    #|    "remote": { "$ref": "https://example.test/schema.json#/x", "description": "external" },
    #|    "anchored": { "$ref": "#item", "$id": "urn:x", "$anchor": "item" }
    #|  },
    #|  "$defs": { "item": { "type": "object", "properties": { "id": { "type": "string", "format": "uuid" } } } },
    #|  "$schema": "https://json-schema.org/draft/2020-12/schema"
    #|}
    #|
  let dirty : Json = @json.parse(raw) catch {
    _ => fail("fixture json must parse")
  }
  let clean = sanitize_tool_schema(dirty)
  guard clean is Json::Object(fields) else { fail("expected object schema") }
  // The Kernel compiles one dialect and resolves in-document refs only.
  assert_eq(fields.get("$schema"), None)
  guard fields.get("properties") is Some(Json::Object(props)) else {
    fail("expected properties")
  }
  assert_eq(
    props.get("local"),
    Some(Json::object({ "$ref": Json::string("#/$defs/item") })),
  )
  // An unresolvable target loosens to unconstrained instead of failing the
  // whole catalog; sibling annotations survive.
  assert_eq(
    props.get("remote"),
    Some(Json::object({ "description": Json::string("external") })),
  )
  assert_eq(
    props.get("anchored"),
    Some(Json::object({ "$ref": Json::string("#item") })),
  )
  guard fields.get("$defs") is Some(Json::Object(defs)) else {
    fail("expected $defs")
  }
  guard defs.get("item") is Some(Json::Object(item)) else {
    fail("expected $defs.item")
  }
  guard item.get("properties") is Some(Json::Object(item_props)) else {
    fail("expected nested properties")
  }
  assert_eq(
    item_props.get("id"),
    Some(
      Json::object({
        "type": Json::string("string"),
        "format": Json::string("uuid"),
      }),
    ),
  )
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
test "sanitize preserves documentation and validation fields" {
  let long_desc = "d".repeat(1200) + "-critical-description-tail"
  let long_title = "t".repeat(400) + "-critical-title-tail"
  let examples = Json::array([Json::string("example payload")])
  let dirty = Json::object({
    "type": Json::string("string"),
    "description": Json::string(long_desc),
    "title": Json::string(long_title),
    "enum": Json::array([Json::string("a"), Json::string("b")]),
    "const": Json::string("a"),
    "default": Json::string("a"),
    "examples": examples,
  })
  guard sanitize_tool_schema(dirty) is Json::Object(clean) else {
    fail("expected object schema")
  }
  assert_eq(clean.get("description"), Some(Json::string(long_desc)))
  assert_eq(clean.get("title"), Some(Json::string(long_title)))
  assert_true(clean.get("enum") is Some(Json::Array(_)))
  assert_true(clean.get("const") is Some(Json::String("a")))
  assert_true(clean.get("default") is Some(Json::String("a")))
  assert_eq(clean.get("examples"), Some(examples))
}
