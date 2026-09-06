///|
/// Copy-paste snippet templates for the system prompt. Each block is one
/// `mbtx` call's `source`, using only APIs that exist in the vendored
/// moonbitlang/async sources (shell: `Cmd::Cmd`, `Cmd::output`,
/// `Output::stdout/stderr/exit_code`, `glob`; fs: `readdir`, `kind`,
/// `file_size`).
/// `moonbitlang/async` must be imported wherever `async fn main` appears;
/// `file_size` fails on directories, so it is gated on `kind`.
let mbtx_snippets : String =
  #|```
  #|import {
  #|  "moonbitlang/async",
  #|  "moonbitlang/async/shell"
  #|}
  #|
  #|async fn main raise {
  #|  let out = @shell.Cmd("git", ["log", "--oneline", "-5"]).output()
  #|  println(out.stdout())
  #|}
  #|```
  #|
  #|```
  #|import {
  #|  "moonbitlang/async",
  #|  "moonbitlang/async/fs"
  #|}
  #|
  #|async fn main raise {
  #|  for name in @fs.readdir(".", sort=true) {
  #|    if @fs.kind(name) is @fs.FileKind::Directory {
  #|      println("\{name}/")
  #|    } else {
  #|      println("\{name} \{@fs.file_size(name)}")
  #|    }
  #|  }
  #|}
  #|```
  #|
  #|```
  #|import {
  #|  "moonbitlang/async",
  #|  "moonbitlang/async/shell"
  #|}
  #|
  #|async fn main raise {
  #|  for path in @shell.glob("src/**/*.mbtx") {
  #|    println(path)
  #|  }
  #|}
  #|```
  #|
  #|```
  #|import {
  #|  "moonbitlang/async",
  #|  "moonbitlang/async/shell"
  #|}
  #|
  #|async fn main raise {
  #|  let out = @shell.Cmd("moon", ["test"]).output(max_output_bytes=262144)
  #|  println(out.stdout())
  #|  if out.exit_code() != 0 {
  #|    println(out.stderr())
  #|  }
  #|}
  #|```

///|
/// System prompt section for mbtx/cmd. The allowlist must appear in BOTH the
/// tool descriptions and the system prompt — missing either side is how the
/// model drifts back to shell habits. The text is derived only from
/// constructor state, so it is byte-for-byte stable for the whole agent
/// lifetime (the port's contract).
pub impl @posoco.SystemPromptContributor for MbtxTools with fn system_prompt(
  self : MbtxTools,
) -> String {
  "## mbtx + cmd — you can run commands\n\nA single whitelisted command goes straight through the `cmd` tool (literal argv); full automation is a one-file MoonBit script through `mbtx`. You can run moon, git, gh, rg, diff. When unsure about MoonBit wording, submit anyway — a BUILD failure is cheap and tells you exactly what to fix; one fix beats ten minutes of hesitation.\n\nAllowed subprocess programs:\n" +
  allowlist_table(self.allowlist) +
  "Denied: any shell or interpreter (sh, bash, zsh, fish, python, node, deno), xargs, curl/wget. Writes are limited to the call's temporary directory — change workspace files with the write/edit tools, never from inside the script. Prefer MoonBit over coreutils:\n" +
  coreutils_substitutions +
  "Minimal shapes to copy (each block is one mbtx call's `source`):\n\n" +
  mbtx_snippets +
  "\nThe script has no writable scratch space — keep results in strings and print them; output is truncated at 64KB (tail kept). Offline: pure-core programs build without network; programs with imports (e.g. moonbitlang/async/shell) need one `moon update` on first use."
}
