///|
// Schema sanitization for externally sourced MCP tool definitions.
//
// The Kernel's catalog accepts a JSON Schema subset (ADR §2.7): anything
// carrying an unsupported keyword (`anyOf`, `minimum`, `format`, …) is a
// composition hard failure, and one rejected tool rejects the WHOLE catalog
// refresh — so a single real-world server schema would make every MCP tool
// invisible. External schemas are not under the host's control, so the
// bridge adapts them at the boundary: keep the parameter shape and validation
// fields (type, properties, items, required, enum, const, default), keep
// bounded title/description documentation, and drop examples plus unsupported
// keywords. Constraints are loosened, never invented; argument validation of
// the sanitized schema stays permissive for the dropped keywords.
//
// Keep the allowlist in sync with the Kernel subset when upgrading posoco.

///|
const MCP_SCHEMA_DESCRIPTION_CHARS = 240

///|
const MCP_SCHEMA_TITLE_CHARS = 120

///|
fn sanitize_schema_doc(value : Json, limit : Int) -> Json? {
  match value {
    Json::String(text) => {
      let clipped = @devkit.truncate_chars(text, limit)
      Some(
        Json::string(if clipped == text { clipped } else { clipped + "…" }),
      )
    }
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
          "properties" =>
            match value {
              Json::Object(props) => {
                let clean : Map[String, Json] = Map::from_array([])
                for name, prop in props {
                  clean[name] = sanitize_tool_schema(prop)
                }
                out[key] = Json::object(clean)
              }
              _ => ()
            }
          "items" => out[key] = sanitize_tool_schema(value)
          "additionalProperties" =>
            match value {
              Json::Object(_) => out[key] = sanitize_tool_schema(value)
              // boolean additionalProperties is meaningful to the Kernel
              Json::True | Json::False => out[key] = value
              _ => ()
            }
          "type" | "required" | "enum" | "const" | "default" => out[key] = value
          "description" =>
            match sanitize_schema_doc(value, MCP_SCHEMA_DESCRIPTION_CHARS) {
              Some(doc) => out[key] = doc
              None => ()
            }
          "title" =>
            match sanitize_schema_doc(value, MCP_SCHEMA_TITLE_CHARS) {
              Some(doc) => out[key] = doc
              None => ()
            }
          // Examples are documentation-only and can dwarf the callable shape.
          "examples" => ()
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
