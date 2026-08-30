///|
/// Narrow platform seam for Nowledge Mem local-file access (plan D7,
/// reduced to its surviving slice): `read_home_file` reads a path relative
/// to the user's home directory, `write_home_file` writes one back (the
/// `/nmem url` persistence path) — the only local IO the extension does
/// after the tool surface moved to MCP (env lookups go through the
/// per-target `runner_get_env`). Production uses `PlatformFs`
/// (per-target file); tests inject a scripted fake.
pub(open) trait NmemPlatform {
  async fn read_home_file(Self, rel : String) -> String?
  async fn write_home_file(Self, rel : String, content : String) -> Result[
    Unit,
    String,
  ]
}
