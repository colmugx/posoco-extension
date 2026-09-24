///|
/// Self-report WebFetchTools' port contributions to the agent composer.
///
/// `extension_id` is the manifest identifier used in composition diagnostics
/// (tool collision messages, observer attribution, etc.). It is NOT used for
/// routing or persistence.
pub impl @posoco.Extension for WebFetchTools with fn extension_id(
  _self : WebFetchTools,
) -> String {
  "posoco_ext_webfetch"
}

///|
/// Declare the ports WebFetchTools contributes: ToolProvider (native+js) and
/// SystemPromptContributor. The same `self` reference appears under both
/// fields because WebFetchTools implements both port traits on one struct.
pub impl @posoco.Extension for WebFetchTools with fn manifest(
  self : WebFetchTools,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_webfetch", tools=[self])
}

///|
/// Expose Extension methods on WebFetchTools for dot-syntax callers and so
/// `&WebFetchTools` coerces to `&@posoco.Extension` when placed in an
/// `Array[&@posoco.Extension]`.
pub extend WebFetchTools with @posoco.Extension::{extension_id, manifest}
