///|
// Bun is a global under bun, so `process` and `Bun` need no require/import.
// `require("os")` is used only for the optional platform-detail probe (same
// precedent as posoco-ext-kimi identity).

///|
extern "js" fn ps1_platform_is_windows() -> Bool =
  #| () => process.platform === "win32"

///|
extern "js" fn ps1_platform_detail() -> String =
  #| () => {
  #|   try { return process.platform + " " + require("os").release() }
  #|   catch { return process.platform }
  #| }

///|
/// Absolute path of `name` on PATH, or "" when not found.
extern "js" fn bun_which(name : String) -> String =
  #| (name) => Bun.which(name) ?? ""

///|
/// Resolve the executable: keep `exe` when it is on PATH; when the default
/// "pwsh" is missing, fall back to "powershell" (Windows PowerShell 5.1) so
/// stock Windows works out of the box.
fn resolve_exe(exe : String) -> String {
  if bun_which(exe) != "" {
    exe
  } else if exe == "pwsh" {
    let fallback = bun_which("powershell")
    if fallback != "" {
      fallback
    } else {
      exe
    }
  } else {
    exe
  }
}
