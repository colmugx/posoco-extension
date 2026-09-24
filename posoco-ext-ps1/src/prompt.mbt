///|
/// Windows-specific guidance for the system prompt. Pure so tests can assert
/// content on any platform.
fn windows_guidance(exe : String, _platform_detail : String) -> String {
  let chaining = if exe.contains("pwsh") {
    "&&/|| supported"
  } else {
    "no &&/||; use ; or if ($?)"
  }
  "Windows shell is PowerShell (\{exe}), not bash. Use $env:NAME, Get-ChildItem, Select-String; \{chaining}. Each call starts at workspace root."
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
