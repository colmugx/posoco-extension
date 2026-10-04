///|
// js (bun) backend wiring: detection reads the node `process` env through
// the reporter's shared `herdr_env` helper; execution spawns the herdr CLI
// through the Bun spawn envelope.

///|
pub fn HerdrDelegate::detect(
  cwd~ : String,
  parent_yolo? : (() -> Bool)? = None,
) -> HerdrDelegate? {
  herdr_delegate_gate(
    herdr_env("HERDR_ENV"),
    herdr_env("HERDR_PANE_ID"),
    herdr_env("HERDR_BIN_PATH"),
    herdr_env("CETAS_RUN_BIN"),
    cwd,
    parent_yolo~,
  )
}

///|
pub impl @posoco.ToolProvider for HerdrDelegate with fn list_tools(
  _self : HerdrDelegate,
) -> Array[@posoco.ToolDef] {
  HerdrDelegate::shared_list_tools()
}

///|
/// Execute the `herdr_delegate` tool on js. Business logic lives in the
/// shared `execute_delegate_impl`; this method only supplies the CLI backend.
pub impl @posoco.ToolProvider for HerdrDelegate with fn execute(
  self : HerdrDelegate,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let name = ctx.name.to_string()
  if name != "herdr_delegate" {
    raise @posoco.RuntimeError::UnknownTool(
      "posoco_ext_herdr_delegate: unknown tool '\{name}'",
    )
  }
  self.execute_delegate_impl(JsHerdrCli::{ }, {
    call_id: ctx.call_id,
    name: ctx.name,
    arguments: ctx.arguments,
  }) catch {
    error =>
      raise @posoco.RuntimeError::InvocationFailed(
        "herdr_delegate: \{error.to_string()}",
      )
  }
}

///|
pub extend HerdrDelegate with @posoco.ToolProvider::{list_tools}
