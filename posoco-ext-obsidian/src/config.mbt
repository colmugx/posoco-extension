///|
/// ObsidianTools — vault tools through the official Obsidian CLI (1.12+).
///
/// The CLI is the only supported transport: it requires the Obsidian desktop
/// app to be running (the first command launches it) and needs no plugin,
/// API key, or certificate setup. Tools are only listed on native and js;
/// wasm/wasm-gc gets an inert provider.
///
/// Write safety has no server-side concurrency primitive on this transport
/// (no `ifMatch`), so read-modify-write protection rests entirely on the
/// injected freshness ledger: reads and outlines record a `FileStamp`, write
/// tools refuse stale targets. Destructive calls (`delete` with `permanent`,
/// `create` with `overwrite`, `patch_note` replace/delete) additionally ask
/// the composed UI for consent via `before_tool`.
pub struct ObsidianTools {
  priv config : ObsidianConfig
  priv freshness : @devkit.FreshnessGuard
  priv mut ui : &@posoco.UiPort?
}

///|
/// Host-supplied configuration. A default construction is a safe read-only
/// citizen: `read_only` defaults to true, so write tools stay unlisted until
/// the host explicitly grants vault access.
pub(all) struct ObsidianConfig {
  /// Obsidian CLI executable (registered by the 1.12+ installer).
  cli_path : String
  /// Vault selector forwarded as the first CLI argument; None uses the
  /// active vault (or the vault containing the process working directory).
  vault : String?
  /// Path prefixes tools may read; empty = whole vault.
  read_paths : Array[String]
  /// Read-only mode: no write tools are listed and execute-level write
  /// gates refuse unconditionally. False grants vault writes; destructive
  /// ones still consent through the composed UI.
  read_only : Bool
  /// Path prefixes tools may write; empty = whole vault (when not
  /// read_only).
  write_paths : Array[String]
  /// Whether the delete tool is listed at all.
  allow_delete : Bool
  /// Never spawn `eval`/`dev:*` regardless of this flag in v1; kept so a
  /// future opt-in is a config change, not a schema change.
  cli_eval_enabled : Bool
}

///|
pub fn ObsidianConfig::ObsidianConfig(
  cli_path? : String = "obsidian",
  vault? : String? = None,
  read_paths? : Array[String] = [],
  read_only? : Bool = true,
  write_paths? : Array[String] = [],
  allow_delete? : Bool = false,
  cli_eval_enabled? : Bool = false,
) -> ObsidianConfig {
  {
    cli_path,
    vault,
    read_paths,
    read_only,
    write_paths,
    allow_delete,
    cli_eval_enabled,
  }
}

///|
pub fn ObsidianTools::new(
  config? : ObsidianConfig = ObsidianConfig::ObsidianConfig(),
  freshness? : @devkit.FreshnessGuard = @devkit.FreshnessGuard::FreshnessGuard(),
) -> ObsidianTools {
  { config, freshness, ui: None, }
}

///|
/// Directories an agent must never touch, on top of the vault root itself.
/// `.obsidian` is app config, `.trash` is Obsidian's soft delete, `.git` is
/// version control, `.smart-env` is the Smart Connections index.
fn reserved_prefixes() -> Array[String] {
  [".obsidian", ".git", ".trash", ".smart-env"]
}

///|
const OBSIDIAN_OWNER = "posoco_ext_obsidian"
