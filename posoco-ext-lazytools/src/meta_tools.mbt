///|
/// The two model-visible meta tools and their argument parsing.
///
/// Keep descriptions terse: resident discovery guidance lives in the stable
/// system-prompt section, while these definitions only need to identify the
/// action and its arguments.

///|
fn meta_tool_defs() -> Array[@posoco.ToolDef] {
  let owner = @posoco.OwnerId::unchecked("posoco_ext_lazytools")
  let provenance : String? = Some("posoco_ext_lazytools")
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("tool_list"),
      description: "Discover deferred tools and their schemas. Omit `keyword` to list all groups; otherwise search groups.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "keyword": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "Space-separated search terms; omit to list all groups",
            ),
          }),
        }),
      }),
      owner,
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance,
    },
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("tool_execute"),
      description: "Execute a deferred tool using a schema returned by `tool_list`.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "tool": Json::object({
            "type": Json::string("string"),
            "description": Json::string("Deferred tool name from tool_list"),
          }),
          "arguments": Json::object({
            "type": Json::string("object"),
            "description": Json::string(
              "Arguments matching the tool schema; omit for no arguments",
            ),
          }),
        }),
        "required": Json::array([Json::string("tool")]),
      }),
      owner,
      policy: @posoco.ExecutionPolicy::Sequential,
      provenance,
    },
  ]
}

///|
/// Extract a required string argument; raises RuntimeError for model-side
/// argument mistakes.
fn required_string(
  tool : String,
  args : Map[String, Json],
  key : String,
) -> String raise @posoco.RuntimeError {
  match args.get(key) {
    Some(Json::String(s)) => s
    Some(_) =>
      raise @posoco.RuntimeError::UnknownTool(
        "\{tool}: '\{key}' must be a string",
      )
    None => raise @posoco.RuntimeError::UnknownTool("\{tool}: missing '\{key}'")
  }
}

///|
/// Extract an optional object argument; absent/null reads as an empty
/// object so providers that unpack arguments never see null.
fn optional_object(
  tool : String,
  args : Map[String, Json],
  key : String,
) -> Map[String, Json] raise @posoco.RuntimeError {
  match args.get(key) {
    Some(Json::Object(obj)) => obj
    Some(Json::Null) | None => Map::from_array([])
    Some(_) =>
      raise @posoco.RuntimeError::UnknownTool(
        "\{tool}: optional '\{key}' must be an object",
      )
  }
}
