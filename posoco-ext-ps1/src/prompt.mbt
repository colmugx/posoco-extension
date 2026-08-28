///|
/// Windows-specific guidance for the system prompt. Pure so tests can assert
/// content on any platform.
fn windows_guidance(exe : String, platform_detail : String) -> String {
  let flavor = if exe.contains("pwsh") {
    "PowerShell 7+ (pwsh): `&&` and `||` pipeline chains are supported."
  } else {
    "Windows PowerShell 5.1: `&&` and `||` are NOT supported; chain statements with `;` or `if ($?)`."
  }
  let lines : Array[String] = []
  if platform_detail != "" {
    lines.push("Environment: Windows (\{platform_detail}).")
  }
  lines.push(
    "The `powershell` tool runs commands in \{exe} with -NoProfile. Use PowerShell syntax, not POSIX shell syntax:",
  )
  lines.push(
    "- Environment variables: `$env:NAME` (not `$NAME`, not `%NAME%`).",
  )
  lines.push("- \{flavor}")
  lines.push(
    "- Prefer PowerShell cmdlets over Unix-only commands: `Select-String` instead of `grep`, `Get-ChildItem` instead of `ls -la`; `ls`/`cat`/`cp` exist only as limited aliases.",
  )
  lines.push(
    "- Each call runs in a fresh PowerShell session in the workspace root; `cd` does not persist between calls.",
  )
  lines.join("\n")
}

///|
/// Stable for the whole process lifetime (platform and resolved exe never
/// change), satisfying the SystemPromptContributor byte-stability contract.
/// Non-Windows hosts get an empty section, which the assembler skips.
pub impl @posoco.SystemPromptContributor for PowerShellTools with fn system_prompt(
  self : PowerShellTools,
) -> String {
  if is_windows() {
    windows_guidance(self.exe, detect_platform())
  } else {
    ""
  }
}
