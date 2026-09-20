///|
/// Stable extension id for the Jev DecisionPort provider.
pub impl @posoco.Extension for JevDecisionPort with fn extension_id(
  _self : JevDecisionPort,
) -> String {
  "posoco_ext_jev"
}

///|
/// Jev contributes exactly one DecisionPort and no policy-bearing hooks/tools.
pub impl @posoco.Extension for JevDecisionPort with fn manifest(
  self : JevDecisionPort,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_jev",
    decisions=[self],
  )
}

///|
pub extend JevDecisionPort with @posoco.Extension::{extension_id, manifest}
