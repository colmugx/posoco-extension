///|
/// One completed CLI invocation. `output` is merged stdout+stderr.
pub(all) struct CliResult {
  exit_code : Int
  output : String
}

///|
/// Subprocess boundary for the Obsidian CLI. Backends supply implementations
/// (`@process` on native, `Bun.spawn` on js); every business rule lives in
/// the shared impls, which only ever see this trait object.
priv trait CliIo {
  /// Run `<cli_path> args...`. Raise = the process could not be spawned or its output could not be decoded (infrastructure failure); a non-zero exit or an `Error: ...` body is a VALUE, not a raise.
  async fn run(self : Self, cli_path : String, args : Array[String]) -> CliResult raise @posoco.RuntimeError
}

///|
/// Classify a completed invocation. The CLI reports business errors (missing
/// file, ambiguous target) as an `Error: ...` line on stdout with exit code
/// 0 — verified against Obsidian 1.13.7 — so the body, not the exit code,
/// decides between success and a tool-reported error.
fn cli_is_business_error(result : CliResult) -> Bool {
  result.exit_code != 0 || result.output.has_prefix("Error: ")
}

///|
/// Prepend the vault selector (must be the first CLI argument) and run.
async fn run_cli(
  io : &CliIo,
  self : ObsidianTools,
  args : Array[String],
) -> CliResult raise @posoco.RuntimeError {
  let full : Array[String] = []
  match self.config.vault {
    Some(name) => full.push("vault=\{name}")
    None => ()
  }
  for a in args {
    full.push(a)
  }
  io.run(self.config.cli_path, full)
}
