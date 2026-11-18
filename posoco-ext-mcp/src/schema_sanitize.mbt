///|
// Schema sanitization for externally sourced MCP tool definitions.
//
// The Kernel compiles tool input schemas with colmugx/json-schema (full
// 2020-12) since Posoco 0.23.0, so every keyword that shapes an argument —
// `$ref`/`$defs`, `oneOf`/`anyOf`/`allOf`/`not`, `format`, `pattern`, numeric
// and string bounds, `prefixItems`/`contains`, `if`/`then`/`else`,
// `unevaluated*` — is enforced at call time and must survive this boundary.
// Dropping them (as the pre-0.23 subset forced) hollows out a third-party
// tool's schema: the model then guesses at nested shapes and enum ranges, and
// the server rejects the call.
//
// External schemas are still not under the host's control, so the sanitizer
// keeps only keywords this repository can compile: vendor extensions, draft
// declarations and non-local `$ref` targets are dropped. Constraints are
// loosened, never invented — a dropped keyword means "unconstrained", so a
// schema we cannot express still yields a callable tool.
//
// Keep the allowlist in sync with the Kernel subset when upgrading posoco.

///|
fn sanitize_schema_map(value : Json) -> Json? {
  match value {
    Json::Object(entries) => {
      let clean : Map[String, Json] = Map::from_array([])
      for name, entry in entries {
        clean[name] = sanitize_tool_schema(entry)
      }
      Some(Json::object(clean))
    }
    _ => None
  }
}

///|
fn sanitize_schema_array(value : Json) -> Json? {
  match value {
    Json::Array(items) => Some(Json::array(items.map(sanitize_tool_schema)))
    _ => None
  }
}

///|
fn sanitize_tool_schema(schema : Json) -> Json {
  match schema {
    Json::Object(fields) => {
      let out : Map[String, Json] = Map::from_array([])
      for key, value in fields {
        match key {
          // Maps of subschemas.
          "properties"
          | "patternProperties"
          | "$defs"
          | "definitions"
          | "dependentSchemas" =>
            match sanitize_schema_map(value) {
              Some(clean) => out[key] = clean
              None => ()
            }
          // A single subschema; the boolean forms are meaningful and pass.
          "items"
          | "additionalProperties"
          | "propertyNames"
          | "contains"
          | "not"
          | "if"
          | "then"
          | "else"
          | "unevaluatedProperties"
          | "unevaluatedItems" =>
            match value {
              Json::Object(_) => out[key] = sanitize_tool_schema(value)
              Json::True | Json::False => out[key] = value
              _ => ()
            }
          // Arrays of subschemas.
          "prefixItems" | "allOf" | "anyOf" | "oneOf" =>
            match sanitize_schema_array(value) {
              Some(clean) => out[key] = clean
              None => ()
            }
          // A reference the compiler can resolve in this document; anything
          // else would hard-fail the whole catalog, so it loosens instead.
          "$ref" =>
            match value {
              Json::String(target) =>
                if target.has_prefix("#") {
                  out[key] = value
                }
              _ => ()
            }
          // Annotations and assertions that need no rewriting.
          "type"
          | "required"
          | "dependentRequired"
          | "enum"
          | "const"
          | "title"
          | "description"
          | "default"
          | "examples"
          | "deprecated"
          | "readOnly"
          | "writeOnly"
          | "format"
          | "pattern"
          | "minLength"
          | "maxLength"
          | "minimum"
          | "maximum"
          | "exclusiveMinimum"
          | "exclusiveMaximum"
          | "multipleOf"
          | "minItems"
          | "maxItems"
          | "uniqueItems"
          | "minContains"
          | "maxContains"
          | "minProperties"
          | "maxProperties" => out[key] = value
          // `$schema`/`$id`/`$anchor`/`$dynamic*`/`$comment`/`$vocabulary`
          // and every vendor extension are dropped: the Kernel compiles one
          // dialect, and a declared one it does not know fails the catalog.
          _ => ()
        }
      }
      Json::object(out)
    }
    Json::True => schema
    // schema:false rejects every instance; an external tool that declares it
    // would become uncallable — treat it as unconstrained instead.
    Json::False => Json::boolean(true)
    _ => Json::boolean(true)
  }
}
