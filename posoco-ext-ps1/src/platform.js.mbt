///|
// js backend: node:os/node:fs via #module injection (`process` is a global).

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
#module("node:fs")
extern "js" fn fs_exists_sync(path : String) -> Bool = "existsSync"

///|
extern "js" fn node_which(exists : (String) -> Bool, name : String) -> String =
  #| (exists, name) => {
  #|   if (name.includes("/") || name.includes("\\")) {
  #|     try { return exists(name) ? name : "" } catch { return "" }
  #|   }
  #|   const isWin = process.platform === "win32"
  #|   const dirs = (process.env.PATH ?? "").split(isWin ? ";" : ":").filter(Boolean)
  #|   const exts = isWin
  #|     ? (process.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").split(";")
  #|     : []
  #|   const candidates = [name, ...exts.map((ext) => name + ext)]
  #|   for (const dir of dirs) {
  #|     const base = dir.endsWith("/") || dir.endsWith("\\") ? dir : dir + (isWin ? "\\" : "/")
  #|     for (const candidate of candidates) {
  #|       try { if (exists(base + candidate)) return base + candidate } catch {}
  #|     }
  #|   }
  #|   return ""
  #| }

///|
/// Resolve the executable: keep `exe` when it is on PATH; when the default
/// "pwsh" is missing, fall back to "powershell" (Windows PowerShell 5.1) so
/// stock Windows works out of the box.
fn resolve_exe(exe : String) -> String {
  if node_which(fs_exists_sync, exe) != "" {
    exe
  } else if exe == "pwsh" {
    let fallback = node_which(fs_exists_sync, "powershell")
    if fallback != "" {
      "powershell"
    } else {
      exe
    }
  } else {
    exe
  }
}
