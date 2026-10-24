///|
/// Stable extension id for the TypeSafe DecisionPort provider.
pub impl @posoco.Extension for TypesafeDecisionPort with fn extension_id(
  _self : TypesafeDecisionPort,
) -> String {
  "posoco_ext_typesafe"
}

///|
/// TypeSafe contributes exactly one DecisionPort and no policy-bearing hooks/tools.
pub impl @posoco.Extension for TypesafeDecisionPort with fn manifest(
  self : TypesafeDecisionPort,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_typesafe", decisions=[self])
}

///|
pub extend TypesafeDecisionPort with @posoco.Extension::{extension_id, manifest}
