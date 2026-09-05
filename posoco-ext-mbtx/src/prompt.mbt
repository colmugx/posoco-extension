///|
/// System prompt section for mbtx. The allowlist must appear in BOTH the
/// tool description and the system prompt — missing either side is how the
/// model drifts back to shell habits. The text is derived only from
/// constructor state, so it is byte-for-byte stable for the whole agent
/// lifetime (the port's contract).
pub impl @posoco.SystemPromptContributor for MbtxTools with fn system_prompt(
  self : MbtxTools,
) -> String {
  "## mbtx — MoonBit scripts instead of a shell\n\nThere is no shell. Submit one single-file MoonBit (.mbtx) program per call; it is compiled and run under a sandbox policy, and subprocesses spawn as literal argv. Allowed subprocess programs:\n" +
  allowlist_table(self.allowlist) +
  "Denied: any shell or interpreter (sh, bash, zsh, fish, python, node, deno), xargs, curl/wget. Writes are limited to the call's temporary directory — change workspace files with the write/edit tools, never from inside the script.\n\nPrefer MoonBit over coreutils:\n" +
  coreutils_substitutions +
  "Offline: pure-core programs build without network; programs with imports (e.g. moonbitlang/async/shell) need one `moon update` on first use."
}
