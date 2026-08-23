///|
/// Outcome of one `nmem` CLI invocation. `exit` follows the platform process
/// exit code on a completed run; the sentinel `-1` marks a run that never
/// completed — cancelled by timeout (`stderr = "timeout"`) or failed to spawn
/// (`stderr` carries the spawn failure text).
pub(all) struct CliOutcome {
  exit : Int
  stdout : String
  stderr : String
} derive(Debug)

///|
/// Exit sentinel shared by both platform runners: the CLI never ran to
/// completion (timed out or failed to spawn).
pub const NMEM_CLI_ABORT_EXIT : Int = -1

///|
/// Narrow platform seam for Nowledge Mem CLI and home-file access (plan D7):
/// `run_cli` spawns `nmem` with `args` under `timeout_ms`; `read_home_file`
/// reads a path relative to the user's home directory. Production uses
/// `PlatformRunner` (per-target file); tests inject a scripted fake.
pub(open) trait NmemRunner {
  async fn run_cli(Self, args : Array[String], timeout_ms~ : Int) -> CliOutcome
  async fn read_home_file(Self, rel : String) -> String?
}
