///|
/// Project a Pi tool's JSON Schema into the subset posoco core accepts.
///
/// Posoco core hard-fails agent composition when a catalog tool's input
/// schema contains any keyword outside its supported JSON Schema subset
/// (kernel_exec/schema_validation.mbt), while Pi tools (TypeBox-based)
/// freely use numeric constraints and unions. This projector is therefore
/// lossy BY DESIGN for the LLM-facing schema: it keeps only keywords posoco
/// core understands and drops the rest. Runtime validation authority stays
/// with the Pi extension — tools receive raw arguments and validate them
/// themselves at execution time.
///
/// Kept: type (string form only), description, properties (recursively
/// projected), items (object form projected; boolean kept; tuple form
/// dropped), required (array form), enum (array form), const, and
/// additionalProperties (boolean kept; object form projected). Unions
/// (anyOf/oneOf/allOf) and every other unsupported or unrecognized keyword
/// are dropped, leaving the parameter unconstrained but callable. The
/// projector never fails: any schema shape passes through minus the keys it
/// does not know.
fn project_tool_schema(schema : Json) -> Json {
  match schema {
    Json::Object(fields) => Json::object(project_schema_fields(fields))
    other => other
  }
}

///|
fn project_schema_fields(fields : Map[String, Json]) -> Map[String, Json] {
  let out : Map[String, Json] = Map::from_array([])
  for key in fields.keys() {
    let value = fields[key]
    match key {
      "type" => if value is Json::String(_) { out["type"] = value }
      "description" =>
        if value is Json::String(_) {
          out["description"] = value
        }
      "properties" =>
        match value {
          Json::Object(props) => {
            let projected : Map[String, Json] = Map::from_array([])
            for prop in props.keys() {
              projected[prop] = project_tool_schema(props[prop])
            }
            out["properties"] = Json::object(projected)
          }
          _ => ()
        }
      "items" =>
        match value {
          Json::Object(_) => out["items"] = project_tool_schema(value)
          Json::True => out["items"] = value
          Json::False => out["items"] = value
          _ => ()
        }
      "required" => if value is Json::Array(_) { out["required"] = value }
      "enum" => if value is Json::Array(_) { out["enum"] = value }
      "const" => out["const"] = value
      "additionalProperties" =>
        match value {
          Json::True => out["additionalProperties"] = value
          Json::False => out["additionalProperties"] = value
          Json::Object(_) =>
            out["additionalProperties"] = project_tool_schema(value)
          _ => ()
        }
      _ => ()
    }
  }
  out
}

///|
/// Apply project_tool_schema to every "parameters" field in a catalog JSON
/// document (array or snapshot object), so every catalog view matches what
/// posoco core will accept at composition time.
fn project_catalog_json(value : Json) -> Json {
  match value {
    Json::Object(fields) => {
      let out : Map[String, Json] = Map::from_array([])
      for key in fields.keys() {
        out[key] = if key == "parameters" {
          project_tool_schema(fields[key])
        } else {
          project_catalog_json(fields[key])
        }
      }
      Json::object(out)
    }
    Json::Array(items) => {
      let projected : Array[Json] = []
      for item in items {
        projected.push(project_catalog_json(item))
      }
      Json::array(projected)
    }
    other => other
  }
}
