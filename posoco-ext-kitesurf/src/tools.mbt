///|
/// Two non-interactive Quick Actions. Neither exposes credentials or arbitrary
/// browser/CDP commands to the model.
fn kitesurf_tool_def(name : String, description : String) -> @posoco.ToolDef {
  @posoco.ToolDef(
    name=@posoco.ToolName::unchecked(name),
    description~,
    input_schema=Json::object({
      "type": Json::string("object"),
      "properties": Json::object({
        "url": Json::object({
          "type": Json::string("string"),
          "description": Json::string("Absolute public http/https URL"),
        }),
      }),
      "required": Json::array([Json::string("url")]),
    }),
    owner=@posoco.OwnerId::unchecked("posoco_ext_kitesurf"),
    policy=@posoco.ExecutionPolicy::Parallel,
    provenance=Some("posoco_ext_kitesurf"),
  )
}

///|
pub impl @posoco.ToolProvider for KitesurfTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  [
    kitesurf_tool_def(
      "kitesurf_markdown",
      "Render a public webpage with Cloudflare Kitesurf and extract Markdown. Stateless; no browser session is preserved.",
    ),
    kitesurf_tool_def(
      "kitesurf_accessibility_tree",
      "Render a public webpage with Cloudflare Kitesurf and return the accessibility tree as JSON. Stateless; no browser session is preserved.",
    ),
  ]
}

///|
/// Invalid arguments are model-correctable business errors. Unknown tool
/// names are runtime errors; transport/service failures become reported errors.
pub impl @posoco.ToolProvider for KitesurfTools with fn execute(
  self : KitesurfTools,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let action = match ctx.name.to_string() {
    "kitesurf_markdown" => "markdown"
    "kitesurf_accessibility_tree" => "accessibilityTree"
    _ => raise @posoco.RuntimeError::UnknownTool("kitesurf: unknown tool")
  }
  let url = match ctx.arguments {
    Object(fields) =>
      match fields.get("url") {
        Some(String(url)) => url
        _ =>
          return @posoco.ToolOutcome::ToolReportedError(
            content="kitesurf: 'url' must be a string",
            structured=None,
          )
      }
    _ =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="kitesurf: arguments must be an object",
        structured=None,
      )
  }
  match self.quick_action(action, url) {
    Err(error) =>
      @posoco.ToolOutcome::ToolReportedError(content=error, structured=None)
    Ok((content, truncated)) =>
      @posoco.ToolOutcome::Success(
        content~,
        structured=Some(Json::object({
          "action": Json::string(action),
          "url": Json::string(url),
          "engine": Json::string("kitesurf"),
          "truncated": Json::boolean(truncated),
        })),
      )
  }
}

///|
pub extend KitesurfTools with @posoco.ToolProvider::{list_tools, execute}
