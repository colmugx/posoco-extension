fn continuity_string_property(description : String) -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("string")),
      ("description", Json::string(description)),
    ]),
  )
}

fn continuity_string_array_property(description : String) -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("array")),
      ("description", Json::string(description)),
      (
        "items",
        Json::object(Map::from_array([("type", Json::string("string"))])),
      ),
    ]),
  )
}

fn continuity_object_schema(
  properties : Map[String, Json],
  required : Array[String],
) -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      ("properties", Json::object(properties)),
      ("required", Json::array(required.map(fn(v) { Json::string(v) }))),
    ]),
  )
}

fn continuity_tool_def(
  name : String,
  description : String,
  input_schema : Json,
) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(name),
    description,
    input_schema,
    owner: @posoco.OwnerId::unchecked("posoco_ext_continuity"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("posoco_ext_continuity"),
  }
}

fn checkpoint_tool_schema() -> Json {
  continuity_object_schema(
    Map::from_array([
      (
        "candidate_id",
        continuity_string_property("Opaque candidate id supplied by Session Continuity"),
      ),
      ("goal", continuity_string_property("Goal of the historical segment")),
      (
        "completed",
        continuity_string_array_property("Completed work worth carrying forward"),
      ),
      (
        "decisions",
        continuity_string_array_property("Important decisions and rationale"),
      ),
      (
        "artifacts",
        continuity_string_array_property("Relevant files, symbols, commands or artifacts"),
      ),
      (
        "facts",
        continuity_string_array_property("Exact facts, identifiers or values worth preserving"),
      ),
      (
        "open_threads",
        continuity_string_array_property("Unresolved work that remains relevant"),
      ),
    ]),
    ["candidate_id", "goal"],
  )
}

fn search_tool_schema() -> Json {
  continuity_object_schema(
    Map::from_array([
      ("query", continuity_string_property("Exact historical text or lexical query")),
    ]),
    ["query"],
  )
}

fn read_tool_schema() -> Json {
  continuity_object_schema(
    Map::from_array([
      ("ref", continuity_string_property("History reference returned by search")),
      (
        "cursor",
        continuity_string_property("Optional non-negative character cursor; defaults to 0"),
      ),
    ]),
    ["ref"],
  )
}

///|
pub impl @posoco.ToolProvider for ContinuityExtension with fn list_tools(
  _self : ContinuityExtension,
) -> Array[@posoco.ToolDef] {
  [
    continuity_tool_def(
      "session_checkpoint",
      "Archive a system-selected settled history segment and prepare its checkpoint",
      checkpoint_tool_schema(),
    ),
    continuity_tool_def(
      "session_history_search",
      "Search exact archived history for the current session",
      search_tool_schema(),
    ),
    continuity_tool_def(
      "session_history_read",
      "Read a bounded page from one archived history entry",
      read_tool_schema(),
    ),
    continuity_tool_def(
      "session_continuity_status",
      "Report Session Continuity state for the current session",
      continuity_object_schema(Map::from_array([]), []),
    ),
  ]
}
