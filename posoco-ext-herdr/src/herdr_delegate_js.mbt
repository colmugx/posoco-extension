///|
// js (bun) backend wiring: detection reads Bun.env through the reporter's
// shared `herdr_env` helper; execution spawns the herdr CLI through the Bun
// spawn envelope.

///|
pub fn HerdrDelegate::detect(cwd~ : String) -> HerdrDelegate? {
  herdr_delegate_gate(
    herdr_env("HERDR_ENV"),
    herdr_env("HERDR_PANE_ID"),
    herdr_env("HERDR_BIN_PATH"),
    herdr_env("CETAS_HEADLESS_BIN"),
    cwd,
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
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  if name != "herdr_delegate" {
    raise @posoco.RuntimeError::UnknownTool(
      "posoco_ext_herdr_delegate: unknown tool '\{name}'",
    )
  }
  self.execute_delegate_impl(JsHerdrCli::{ }, call) catch {
    error =>
      raise @posoco.RuntimeError::InvocationFailed(
        "herdr_delegate: \{error.to_string()}",
      )
  }
}
