///|
/// Minimal persistence required by the profiles extension. This is an
/// extension-local seam, not a Posoco port (handoff's `HandoffStore`
/// precedent): the package performs zero IO, so every host — cetas-js,
/// cetas-acp, headless — adapts its own storage.
///
/// - `read_all` hands back every stored manifest as (level, raw content)
///   pairs. The level vocabulary is host-owned ("user" / "project" per the
///   redesign; project overrides user when ids collide — Q12). The content
///   is the raw manifest text the host stored; parse it with
///   `parse_profile_manifest`.
/// - `write` persists one manifest under a level. Hosts key the storage by
///   the manifest id — its file name stem.
pub(open) trait ProfileStore {
  fn read_all(Self) -> Result[Array[(String, String)], String]
  fn write(Self, level : String, manifest : ProfileManifest) -> Result[
    Unit,
    String,
  ]
}
