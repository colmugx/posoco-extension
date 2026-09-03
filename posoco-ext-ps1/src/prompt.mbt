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
    "IMPORTANT: This is Windows. The `powershell` tool runs commands in \{exe} with -NoProfile — the shell is PowerShell, NOT bash. Do not reach for bash out of habit; bash commands like `grep`, `awk`, `sed`, `export`, or `2>/dev/null` do not work here. Translate them with the pairs below.",
  )
  lines.push(
    "- Environment variables: read `$env:NAME` (not `$NAME`, not `%NAME%`); set with `$env:NAME = \"value\"` (not `export`).",
  )
  lines.push("- \{flavor}")
  lines.push(
    "- PowerShell pipelines .NET objects, not text, so the Unix text tools (`grep`, `sed`, `awk`, `cut`, `tr`) do not exist on Windows. Filter objects with `Where-Object`, reshape them with `ForEach-Object`, search text with `Select-String`, transform strings with `-replace`/`-split`.",
  )
  lines.push(
    "- Text translations: `grep pat file` → `Select-String pat file`; `sed 's/a/b/' f` → `(Get-Content f) -replace 'a','b'`; `awk '{print $1}'` → `... | ForEach-Object { ($_ -split '\\s+')[0] }`; `2>/dev/null` → `2>$null` (there is no `/dev/null`).",
  )
  lines.push(
    "- File listings: `ls -la` → `Get-ChildItem -Force` (PowerShell prints Mode/Length/LastWriteTime details by default; `-Force` reveals hidden items); `ls -R` or `find . -name x` → `Get-ChildItem -Recurse -Filter x`. `ls`/`cat`/`cp` exist only as thin aliases of the cmdlets — bash flags fail because `-la` is not a PowerShell parameter.",
  )
  lines.push(
    "- Misc translations: `cat f` → `Get-Content f`; `which x` → `Get-Command x`; `rm` → `Remove-Item`; `mkdir` → `New-Item -ItemType Directory`.",
  )
  lines.push(
    "- Paths use backslashes natively: `C:\\repo\\src\\main.rs`, not `C:/repo/src/main.rs`. Cmdlets tolerate forward slashes, but some native executables reject them; quote paths containing spaces.",
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
