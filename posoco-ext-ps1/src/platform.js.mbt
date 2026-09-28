///|
// `process` and `Bun` are globals under bun and need no import. node:os for
// the optional platform-detail probe is bound with `#module` and injected
// into the wrapper as a value (pattern follows posoco-ext-workspace
// fs_port.js.mbt / moonbitlang/x/fs/fs_js.mbt).

///|
extern "js" fn ps1_platform_is_windows() -> Bool =
  #| () => process.platform === "win32"

///|
#module("node:os")
extern "js" fn os_release() -> String = "release"

///|
extern "js" fn ps1_js_platform_detail(release : () -> String) -> String =
  #| (release) => {
  #|   try { return process.platform + " " + release() }
  #|   catch { return process.platform }
  #| }

///|
fn ps1_platform_detail() -> String {
  ps1_js_platform_detail(os_release)
}

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
