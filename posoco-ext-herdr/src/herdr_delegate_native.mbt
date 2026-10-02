///|
// Native+wasm backend wiring: detection reads the herdr-injected environment via
// @env; execution spawns the herdr CLI through @process.

///|
pub fn HerdrDelegate::detect(
  cwd~ : String,
  parent_yolo? : (() -> Bool)? = None,
) -> HerdrDelegate? {
  herdr_delegate_gate(
    @env.get_env_var("HERDR_ENV"),
    @env.get_env_var("HERDR_PANE_ID"),
    @env.get_env_var("HERDR_BIN_PATH"),
    @env.get_env_var("CETAS_HEADLESS_BIN"),
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
pub extend HerdrDelegate with @posoco.ToolProvider::{list_tools}

///|
/// Execute the `herdr_delegate` tool on native. Business logic lives in the
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
  self.execute_delegate_impl(NativeHerdrCli::{ }, {
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
