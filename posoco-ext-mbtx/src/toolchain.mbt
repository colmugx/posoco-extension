///|
/// Resolve a complete MoonBit runner for MBTX without relying on application
/// code to install the toolchain. The user's toolchain always has priority.
pub(all) enum ToolchainOrigin {
  System
  Managed
} derive(Debug, Eq)

///|
pub extend ToolchainOrigin with Eq::{equal, not_equal}

///|
pub(all) struct ResolvedToolchain {
  origin : ToolchainOrigin
  version : String
  launcher : Launcher
  moon : String
  moonx : String
  moonrun : String
  bin_dir : String
}

///|
/// Pinned to the OpenSeek Desktop compiler seed, not "latest". The installer
/// is required to produce this compiler version before the stage is accepted.
pub const MBTX_TOOLCHAIN_VERSION : String = "0.10.15+943464bfa"

///|
pub struct ToolchainManager {
  priv lock : @async.Mutex
  priv mut resolved : ResolvedToolchain?
  priv mut phase : String
  priv mut reason : String
  priv bus : @devkit.EventBus?
  priv home : String
}

///|
pub fn ToolchainManager::ToolchainManager(
  bus? : @devkit.EventBus,
  home? : String,
) -> ToolchainManager {
  {
    lock: @async.Mutex(),
    resolved: None,
    phase: "uninitialized",
    reason: "",
    bus,
    home: home.unwrap_or(@devkit.home_dir().unwrap_or("")),
  }
}

///|
fn mbtx_exe(name : String) -> String {
  if mbtx_is_windows() { name + ".exe" } else { name }
}

///|
fn mbtx_bin(root : String, name : String) -> String {
  root + "/bin/" + mbtx_exe(name)
}

///|
fn mbtx_env(tc : ResolvedToolchain) -> Map[String, String] {
  if tc.bin_dir == "PATH" || tc.bin_dir == "" {
    return Map([])
  }
  {
    "PATH": tc.bin_dir + (if mbtx_is_windows() { ";" } else { ":" }) +
      @env.get_env_var("PATH").unwrap_or(""),
  }
}

///|
fn ToolchainManager::publish(
  self : ToolchainManager,
  phase : String,
  reason : String,
) -> Unit {
  self.phase = phase
  self.reason = reason
  match self.bus {
    None => ()
    Some(bus) =>
      if phase == "ready" {
        @devkit.publish_status_unregister(
          bus,
          source="posoco_ext_mbtx",
          segment="mbtx",
        )
      } else {
        @devkit.publish_status_register(
          bus,
          source="posoco_ext_mbtx",
          segment="mbtx",
          priority=85,
          value="mbtx: " + phase,
          color=if phase == "failed" { "error" } else { "info" },
        )
      }
  }
}

///|
pub fn ToolchainManager::status(self : ToolchainManager) -> String {
  match self.resolved {
    Some(tc) => {
      let source = if tc.origin == System { "system" } else { "managed" }
      "MBTX: ready\nToolchain: " + source + "\nVersion: " +
      tc.version + "\nLauncher: " +
      (if tc.launcher == Moonx { "moonx" } else { "moon" }) +
      "\nMoon: " + tc.moon + "\nMoonx: " + tc.moonx +
      "\nMoonrun: " + tc.moonrun
    }
    None => "MBTX: " + self.phase +
      (if self.reason == "" { "" } else { "\nDetail: " + self.reason })
  }
}

///|
/// Testable probe: moonx-only remains a valid configuration. Moon requires
/// moonrun, and the managed distribution is additionally compiler-version
/// checked. Failure to spawn or timeouts mean "not usable".
async fn mbtx_probe(program : String, args : Array[String]) -> String? {
  let result = @async.with_timeout(15000, () => {
    collect_process(program, args, None, max_bytes=16384)
  }) catch { _ => return None }
  if result.0 == 0 { Some(result.1.trim().to_owned()) } else { None }
}

///|
async fn mbtx_candidate(
  origin : ToolchainOrigin,
  moon : String,
  moonx : String,
  moonrun : String,
  bin_dir : String,
) -> ResolvedToolchain? {
  match mbtx_probe(moonx, ["--version"]) {
    Some(version) =>
      return Some({
        origin,
        version,
        launcher: Moonx,
        moon,
        moonx,
        moonrun,
        bin_dir,
      })
    None => ()
  }
  match (mbtx_probe(moon, ["--version"]), mbtx_probe(moonrun, ["--version"])) {
    (Some(version), Some(_)) =>
      Some({
        origin,
        version,
        launcher: Moon,
        moon,
        moonx,
        moonrun,
        bin_dir,
      })
    _ => None
  }
}

///|
pub async fn ToolchainManager::ensure_ready(
  self : ToolchainManager,
) -> ResolvedToolchain {
  self.lock.acquire()
  defer self.lock.release()
  match self.resolved {
    Some(tc) => return tc
    None => ()
  }
  let tc = self.discover() catch {
    error => {
      self.publish("failed", error.to_string())
      raise error
    }
  }
  self.resolved = Some(tc)
  self.publish("ready", "")
  tc
}

///|
async fn ToolchainManager::discover(self : ToolchainManager) -> ResolvedToolchain {
  self.publish("checking", "looking for a usable MoonBit runner")
  match mbtx_candidate(System, "moon", "moonx", "moonrun", "PATH") {
    Some(tc) => return tc
    None => ()
  }
  if self.home == "" {
    raise RuntimeError::ToolchainUnavailable(
      "MoonBit is unavailable and no user home directory could be resolved",
    )
  }
  let official = self.home + "/.moon/bin"
  match mbtx_candidate(
    System,
    official + "/" + mbtx_exe("moon"),
    official + "/" + mbtx_exe("moonx"),
    official + "/" + mbtx_exe("moonrun"),
    official,
  ) {
    Some(tc) => return tc
    None => ()
  }
  let root = self.home + "/.cetas/moon_toolchain"
  match self.managed_candidate(root + "/current") {
    Some(tc) => return tc
    None => ()
  }
  self.provision(root)
}

///|
async fn ToolchainManager::managed_candidate(
  self : ToolchainManager,
  root : String,
) -> ResolvedToolchain? {
  match mbtx_probe(mbtx_bin(root, "moonc"), ["-v"]) {
    Some(version) if version.contains(MBTX_TOOLCHAIN_VERSION) =>
      mbtx_candidate(
        Managed,
        mbtx_bin(root, "moon"),
        mbtx_bin(root, "moonx"),
        mbtx_bin(root, "moonrun"),
        root + "/bin",
      )
    _ => None
  }
}

///|
/// Following the OpenSeek CLI bootstrap: download the official installer
/// over HTTPS into a private staging directory. The installer receives
/// MOON_HOME and a pinned requested version; no system installation is
/// modified. Compiler-version validation is mandatory after it exits.
async fn ToolchainManager::install(self : ToolchainManager, root : String, stage : String) -> Unit {
  self.publish("downloading", "fetching MoonBit installer")
  let windows = mbtx_is_windows()
  let suffix = if windows { "powershell.ps1" } else { "unix.sh" }
  let script = root + (if windows { "/install.ps1" } else { "/install.sh" })
  let url = "https://cli.moonbitlang.com/install/" + suffix
  let curl = if windows { "curl.exe" } else { "curl" }
  let (code, output) = collect_process(
    curl,
    [
      "--fail", "--location", "--silent", "--show-error",
      "--proto", "=https", "--proto-redir", "=https",
      "--connect-timeout", "15", "--max-time", "600", "--retry", "2",
      url, "--output", script,
    ],
    None,
  )
  if code != 0 {
    raise RuntimeError::ToolchainUnavailable("MoonBit download: " + output)
  }
  self.publish("initializing", "installing MoonBit into private directory")
  let env : Map[String, String] = {
    "MOON_HOME": stage,
    "MOONBIT_INSTALL_VERSION": MBTX_TOOLCHAIN_VERSION,
    "HOME": root,
    "USERPROFILE": root,
    "PATH": stage + "/bin" + (if windows { ";" } else { ":" }) +
      @env.get_env_var("PATH").unwrap_or(""),
  }
  let (command, args) = if windows {
    ("powershell.exe", [
      "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script,
    ])
  } else {
    ("bash", [script])
  }
  let (exit, diagnostics) = @async.with_timeout(900000, () => {
    collect_process(command, args, None, max_bytes=65536, extra_env=env)
  })
  if exit != 0 {
    raise RuntimeError::ToolchainUnavailable(
      "MoonBit installer exited " + exit.to_string() + ": " + diagnostics,
    )
  }
}

///|
/// @fs file locking serializes independent host processes. A partially
/// written stage is never published as current; retries discard it.
async fn ToolchainManager::provision(self : ToolchainManager, root : String) -> ResolvedToolchain {
  tc_fs_mkdir(root)
  // mkdir is an atomic cross-process lock on native and Node/Bun.
  let lock_dir = root + "/.install.lock"
  let mut acquired = false
  for _ in 0..<600 {
    if tc_fs_try_lock(lock_dir) {
      acquired = true
      break
    }
    @async.sleep(100)
  }
  if !acquired {
    raise RuntimeError::ToolchainUnavailable(
      "timed out waiting for MBTX toolchain installation lock",
    )
  }
  defer tc_fs_unlock(lock_dir)
  let current = root + "/current"
  match self.managed_candidate(current) {
    Some(tc) => return tc
    None => ()
  }
  let stage = root + "/.incoming"
  tc_fs_remove(stage)
  tc_fs_mkdir(stage)
  defer tc_fs_remove(stage)
  self.install(root, stage)
  let moon = mbtx_bin(stage, "moon")
  let moonx = mbtx_bin(stage, "moonx")
  if !tc_fs_exists(moonx) && tc_fs_exists(moon) {
    tc_fs_copy_executable(moon, moonx)
  }
  self.publish("verifying", "checking MoonBit compiler and runner")
  guard self.managed_candidate(stage) is Some(_tc) else {
    raise RuntimeError::ToolchainUnavailable(
      "downloaded MoonBit failed pinned version or runner verification",
    )
  }
  tc_fs_remove(current)
  tc_fs_rename(stage, current)
  match self.managed_candidate(current) {
    Some(tc) => tc
    None => raise RuntimeError::ToolchainUnavailable(
      "managed MoonBit disappeared after installation",
    )
  }
}
