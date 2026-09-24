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
/// Declare the ToolProvider contribution. Continuation and redirect recovery
/// are carried by the tool/result protocol, so no resident prompt is needed.
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
