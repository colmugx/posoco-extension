///|
// Native backend wiring: detection reads the herdr-injected environment via
// @env; execution spawns the herdr CLI through @process.

///|
pub fn HerdrDelegate::detect(cwd~ : String) -> HerdrDelegate? {
  herdr_delegate_gate(
    @env.get_env_var("HERDR_ENV"),
    @env.get_env_var("HERDR_PANE_ID"),
    @env.get_env_var("HERDR_BIN_PATH"),
    @env.get_env_var("CETAS_HEADLESS_BIN"),
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
/// Execute the `herdr_delegate` tool on native. Business logic lives in the
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
  self.execute_delegate_impl(NativeHerdrCli::{ }, call) catch {
    error =>
      raise @posoco.RuntimeError::InvocationFailed(
        "herdr_delegate: \{error.to_string()}",
      )
  }
}
