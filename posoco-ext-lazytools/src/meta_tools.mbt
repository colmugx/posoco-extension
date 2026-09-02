///|
/// The two model-visible meta tools and their argument parsing.
///
/// Descriptions are load-bearing: they teach the discovery workflow
/// (tool_list → schema → tool_execute) without any other prompt surface.

///|
fn meta_tool_defs() -> Array[@posoco.ToolDef] {
  let owner = @posoco.OwnerId::unchecked("posoco_ext_lazytools")
  let provenance : String? = Some("posoco_ext_lazytools")
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("tool_list"),
      description: "Browse or search the deferred (folded) tool catalog. Deferred tools are NOT loaded into this conversation; this is how you discover them. Without arguments, lists every folded group. With `keyword`, only the groups whose id or tools match — and each match returns that group's tools with name, description and full JSON input schema, everything needed to call one. Call results via tool_execute.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "keyword": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "Space-separated keywords matched against extension ids and tool names/descriptions; omit to list every folded group",
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
      description: "Execute a deferred (folded) tool by name. `tool` must be a name returned by tool_list; `arguments` must match that tool's JSON schema as returned by tool_list. The gateway routes the call to the tool's provider and returns the outcome verbatim.",
      input_schema: Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "tool": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "Exact deferred tool name as returned by tool_list",
            ),
          }),
          "arguments": Json::object({
            "type": Json::string("object"),
            "description": Json::string(
              "Arguments object matching the deferred tool's input_schema from tool_list; omit or pass {} when the tool takes no arguments",
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
/// Extract a required string argument, mirroring the read tool's error
/// style (RuntimeError for model-side argument mistakes).
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
