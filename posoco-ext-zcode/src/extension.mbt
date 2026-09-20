///|
pub(all) struct ZcodeExt {
  tools : ZcodeTools
}

///|
pub fn zcode_ext(
  config? : ZcodeConfig = zcode_config(),
  run? : (async (ZcodeTaskArgs) -> String)? = None,
) -> ZcodeExt {
  { tools: zcode_tools(config~, run~), }
}

///|
pub impl @posoco.Extension for ZcodeExt with fn extension_id(_self : ZcodeExt) -> String {
  "posoco_ext_zcode"
}

///|
/// Manifest contribution: the tool provider, plus the same tools value as a
/// Lifecycle contributor (captures the composed Tasks capability at
/// on_compose) and as an Observer (tracks the parent session from scoped
/// events). `requires: [Capability::Tasks]` is what makes the capability
/// appear in the CompositionView. No hooks: core's session inbox owns
/// background-result delivery.
pub impl @posoco.Extension for ZcodeExt with fn manifest(self : ZcodeExt) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_zcode",
    tools=[self.tools],
    lifecycle=[self.tools as &@posoco.Lifecycle],
    observers=[self.tools as &@posoco.Observer],
    requires=[@posoco.Capability::Tasks],
  )
}

///|
/// Composition: capture the Agent-owned task capability delivered because
/// the manifest requires Capability::Tasks. Submitting before run_scoped is
/// refused at the tool layer with an explicit model-visible error.
pub impl @posoco.Lifecycle for ZcodeTools with fn on_compose(
  self : ZcodeTools,
  view : @posoco.CompositionView,
) {
  self.tasks = view.tasks()
}

///|
pub impl @posoco.Lifecycle for ZcodeTools with fn on_shutdown(
  _self : ZcodeTools,
) -> Unit {
  ()
}

///|
pub impl @posoco.Observer for ZcodeTools with fn on_event(
  _self : ZcodeTools,
  _event : @posoco.TurnEvent,
) -> Unit {
  ()
}

///|
/// Track the parent session from scoped events; a background call addresses
/// its TaskSpec to this session so core delivers the outcome here.
pub impl @posoco.Observer for ZcodeTools with fn on_event_at(
  self : ZcodeTools,
  scope : @posoco.EventScope?,
  _event : @posoco.TurnEvent,
) -> Unit {
  match scope {
    Some(s) => self.session = Some(s.session_id.to_string())
    None => ()
  }
}
