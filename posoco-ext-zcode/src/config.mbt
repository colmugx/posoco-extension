///|
/// Extension configuration.
pub(all) struct ZcodeConfig {
  /// Explicit zcode entry point (executable or .cjs). None = auto-discover.
  bin : String?
  /// Explicit node interpreter (only relevant when bin is a .cjs); None =
  /// ZCODE_NODE or plain "node".
  node : String?
  /// v2 credentials file; None = ZCODE_CREDS or <HOME>/.zcode/v2/config.json.
  creds_path : String?
  /// Default permission mode; never default to yolo.
  default_mode : String
  /// Wall-clock ceiling per delegation.
  timeout_ms : Int
}

///|
pub fn zcode_config() -> ZcodeConfig {
  {
    bin: None,
    node: None,
    creds_path: None,
    default_mode: "edit",
    timeout_ms: 1_800_000,
  }
}

///|
/// Validate a permission mode (build/edit/plan/yolo).
pub fn zcode_check_mode(mode : String) -> Result[String, String] {
  if mode == "build" || mode == "edit" || mode == "plan" || mode == "yolo" {
    Ok(mode)
  } else {
    Err("zcode: invalid mode '\{mode}' (expected build|edit|plan|yolo)")
  }
}

///|
/// An explicit `config.bin` or `ZCODE_BIN` is trusted without any probe.
fn zcode_trusted_bin(
  config~ : ZcodeConfig,
  env~ : (String) -> String?,
) -> String? {
  match config.bin {
    Some(b) => Some(b)
    None => env("ZCODE_BIN")
  }
}

///|
/// Windows is detected from the injected env (`OS` == "Windows_NT", else
/// `ProgramFiles` presence) — no compile-time platform switch, so the same
/// rule works for native hosts and for js hosts injecting process.env.
fn zcode_env_is_windows(env~ : (String) -> String?) -> Bool {
  if env("OS") is Some("Windows_NT") {
    return true
  }
  env("ProgramFiles") is Some(_)
}

///|
/// HOME, else USERPROFILE (zcode-acp precedent); None when neither is set.
fn zcode_home_of(env~ : (String) -> String?) -> String? {
  match env("HOME") {
    Some(h) => Some(h)
    None => env("USERPROFILE")
  }
}

///|
/// True for the JS entry points that must run through a node interpreter.
pub fn zcode_bin_is_js(bin : String) -> Bool {
  bin.has_suffix(".cjs") || bin.has_suffix(".mjs") || bin.has_suffix(".js")
}

///|
/// The bare `<dir>/zcode` shape of a PATH-entry candidate; such a hit keeps
/// the bare "zcode" command so the OS resolves the directory at spawn time.
fn zcode_is_path_stub(path : String) -> Bool {
  path.has_suffix("/zcode") || path.has_suffix("\\zcode")
}

///|
/// Directory part of a path (split at the last '/' or '\\'), None for bare
/// names and roots.
fn zcode_parent_dir(path : String) -> String? {
  let cut = match (path.rev_find("/"), path.rev_find("\\")) {
    (Some(a), Some(b)) => if a > b { a } else { b }
    (Some(a), None) => a
    (None, Some(b)) => b
    (None, None) => return None
  }
  if cut <= 0 {
    None
  } else {
    Some(path[:cut].to_owned())
  }
}

///|
/// Siblings to probe around a resolved executable location: the app-server
/// `.cjs` next to it, plus the desktop-app resource layout one level up or
/// down. Used by the .desktop tier (Exec paths) and the symlink tier
/// (readlink-resolved PATH hits).
pub fn zcode_sibling_candidates(path : String) -> Array[String] {
  match zcode_parent_dir(path) {
    Some(dir) =>
      [
        dir + "/zcode.cjs",
        dir + "/../resources/glm/zcode.cjs",
        dir + "/resources/glm/zcode.cjs",
      ]
    None => []
  }
}

///|
/// The static auto-discovery candidates, in order: PATH entries (unix ':' +
/// "/zcode"; windows ';' + "zcode", "zcode.exe", "zcode.cmd" shims per
/// entry), the darwin bundles (system + per-home Applications), the windows
/// bundles (LOCALAPPDATA falling back to <home>\AppData\Local, then both
/// ProgramFiles roots), and the linux bundles (/opt, /usr/share, plus the
/// ZCODE_INSTALL_DIR escape hatch). Empty PATH entries are skipped. An
/// explicit `config.bin` or `ZCODE_BIN` is trusted without a probe, so those
/// cases yield an empty list. No compile-time platform switch: env is
/// injected, so a host simply misses the candidates that do not apply.
pub fn zcode_candidate_paths(
  config~ : ZcodeConfig,
  env~ : (String) -> String?,
) -> Array[String] {
  if zcode_trusted_bin(config~, env~) is Some(_) {
    return []
  }
  let candidates : Array[String] = []
  let windows = zcode_env_is_windows(env~)
  match env("PATH") {
    Some(path) =>
      if windows {
        for dir in path.split(";") {
          if dir != "" {
            let dir = dir.to_owned()
            candidates.push(dir + "\\zcode")
            candidates.push(dir + "\\zcode.exe")
            candidates.push(dir + "\\zcode.cmd")
          }
        }
      } else {
        for dir in path.split(":") {
          if dir != "" {
            candidates.push(dir.to_owned() + "/zcode")
          }
        }
      }
    None => ()
  }
  candidates.push("/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs")
  match zcode_home_of(env~) {
    Some(home) =>
      candidates.push(
        home + "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
      )
    None => ()
  }
  let local_app_data = match env("LOCALAPPDATA") {
    Some(dir) => Some(dir)
    None =>
      match zcode_home_of(env~) {
        Some(home) => Some(home + "\\AppData\\Local")
        None => None
      }
  }
  match local_app_data {
    Some(dir) =>
      candidates.push(dir + "\\Programs\\ZCode\\resources\\glm\\zcode.cjs")
    None => ()
  }
  match env("ProgramFiles") {
    Some(dir) => candidates.push(dir + "\\ZCode\\resources\\glm\\zcode.cjs")
    None => ()
  }
  match env("ProgramFiles(x86)") {
    Some(dir) => candidates.push(dir + "\\ZCode\\resources\\glm\\zcode.cjs")
    None => ()
  }
  candidates.push("/opt/ZCode/resources/glm/zcode.cjs")
  candidates.push("/usr/share/zcode/resources/glm/zcode.cjs")
  match env("ZCODE_INSTALL_DIR") {
    Some(dir) => candidates.push(dir + "/resources/glm/zcode.cjs")
    None => ()
  }
  candidates
}

///|
/// Extract the executable token of one .desktop `Exec=` value: a quoted form
/// runs to the closing quote, otherwise the token ends at the first space
/// (dropping arguments and %U-style field codes).
fn zcode_desktop_exec_token(value : String) -> String {
  if value.has_prefix("\"") {
    for i in 1..<value.length() {
      if value.get_char(i) == Some('"') {
        return value[1:i].trim().to_owned()
      }
    }
    return value[1:].trim().to_owned()
  }
  let mut end = value.length()
  for i in 0..<value.length() {
    if value.get_char(i) == Some(' ') {
      end = i
      break
    }
  }
  value[:end].trim().to_owned()
}

///|
/// Pure .desktop parser: the `Exec=` executable tokens in file order (the
/// first entry's Exec comes first). Handles quoted values, trailing
/// arguments, %U field codes and CRLF; a file without Exec yields [].
pub fn zcode_desktop_exec_paths(content : String) -> Array[String] {
  let out : Array[String] = []
  for line in content.split("\n") {
    let line = line.trim().to_owned()
    if line.has_prefix("Exec=") {
      let token = zcode_desktop_exec_token(line[5:].to_owned())
      if token != "" && !out.contains(token) {
        out.push(token)
      }
    }
  }
  out
}

///|
/// Linux .desktop tier: list the applications directories ($HOME/.local/
/// share/applications first per XDG precedence, then each XDG_DATA_DIRS
/// entry, defaulting to /usr/local/share:/usr/share), read the *zcode*.desktop
/// files (case-insensitive name match) and turn each parsed Exec into its
/// sibling candidates. read_file/list_dir are injected; a failed list or read
/// degrades to a skip. Skipped entirely on windows-shaped envs.
pub async fn zcode_desktop_candidates(
  env~ : (String) -> String?,
  read_file~ : async (String) -> String?,
  list_dir~ : async (String) -> Array[String]?,
) -> Array[String] noraise {
  let out : Array[String] = []
  if zcode_env_is_windows(env~) {
    return out
  }
  let dirs : Array[String] = []
  match zcode_home_of(env~) {
    Some(home) => dirs.push(home + "/.local/share/applications")
    None => ()
  }
  let xdg = match env("XDG_DATA_DIRS") {
    Some(v) => v
    None => ""
  }
  let xdg = if xdg == "" { "/usr/local/share:/usr/share" } else { xdg }
  for dir in xdg.split(":") {
    if dir != "" {
      dirs.push(dir.to_owned() + "/applications")
    }
  }
  let seen : Map[String, Bool] = Map::from_array([])
  for dir in dirs {
    if seen.contains(dir) {
      continue
    }
    seen[dir] = true
    let listed : Array[String]? = list_dir(dir) catch { _ => None }
    match listed {
      Some(files) =>
        for file in files {
          let is_zcode_desktop = (
              file.contains("zcode") || file.contains("ZCode")
            ) &&
            file.has_suffix(".desktop")
          if is_zcode_desktop {
            let content : String? = read_file(dir + "/" + file) catch {
              _ => None
            }
            match content {
              Some(text) =>
                for exec in zcode_desktop_exec_paths(text) {
                  for sibling in zcode_sibling_candidates(exec) {
                    out.push(sibling)
                  }
                }
              None => ()
            }
          }
        }
      None => ()
    }
  }
  out
}

///|
/// Symlink tier (unix): resolve each PATH-entry `zcode` through the injected
/// realpath and offer its sibling candidates (a PATH shim that points into an
/// app install). A realpath failure (missing, dangling) degrades to a skip.
/// Skipped entirely on windows-shaped envs.
pub async fn zcode_symlink_candidates(
  env~ : (String) -> String?,
  realpath~ : async (String) -> String?,
) -> Array[String] noraise {
  let out : Array[String] = []
  if zcode_env_is_windows(env~) {
    return out
  }
  match env("PATH") {
    Some(path) =>
      for dir in path.split(":") {
        if dir != "" {
          let resolved : String? = realpath(dir.to_owned() + "/zcode") catch {
            _ => None
          }
          match resolved {
            Some(real) =>
              for sibling in zcode_sibling_candidates(real) {
                out.push(sibling)
              }
            None => ()
          }
        }
      }
    None => ()
  }
  out
}

///|
/// The full pre-probe list for hosts with read IO: the static candidates
/// (`zcode_candidate_paths`), then the .desktop tier, then the symlink tier.
/// Still IO-free itself — every filesystem answer arrives through the
/// injections, so the list can be computed once and answered from a memo.
pub async fn zcode_probe_paths(
  config~ : ZcodeConfig,
  env~ : (String) -> String?,
  read_file~ : async (String) -> String?,
  list_dir~ : async (String) -> Array[String]?,
  realpath~ : async (String) -> String?,
) -> Array[String] noraise {
  if zcode_trusted_bin(config~, env~) is Some(_) {
    return []
  }
  let out = zcode_candidate_paths(config~, env~)
  for path in zcode_desktop_candidates(env~, read_file~, list_dir~) {
    out.push(path)
  }
  for path in zcode_symlink_candidates(env~, realpath~) {
    out.push(path)
  }
  out
}

///|
/// Command assembly for a resolved bin: a .cjs/.mjs/.js entry is prefixed
/// with the interpreter (config.node → ZCODE_NODE → "node"); anything else
/// spawns directly.
fn zcode_command_for(
  config~ : ZcodeConfig,
  env~ : (String) -> String?,
  bin : String,
) -> Result[(String, Array[String]), ZcodeError] {
  if zcode_bin_is_js(bin) {
    let interpreter = match config.node {
      Some(n) => n
      None =>
        match env("ZCODE_NODE") {
          Some(n) => n
          None => "node"
        }
    }
    Ok((interpreter, [bin, "app-server", "--stdio"]))
  } else {
    Ok((bin, ["app-server", "--stdio"]))
  }
}

///|
/// Resolve over an explicit candidate list (the caller decides the list and
/// answers `exists`): the first existing candidate wins. A PATH-stub hit
/// keeps the bare "zcode" command; every other hit keeps the probed path.
pub fn zcode_resolve_command_from(
  config~ : ZcodeConfig,
  env~ : (String) -> String?,
  candidates~ : Array[String],
  exists~ : (String) -> Bool,
) -> Result[(String, Array[String]), ZcodeError] {
  let mut bin : String? = None
  for path in candidates {
    if exists(path) {
      bin = Some(if zcode_is_path_stub(path) { "zcode" } else { path })
      break
    }
  }
  match bin {
    Some(b) => zcode_command_for(config~, env~, b)
    None => Err(ZcodeBinNotFound)
  }
}

///|
/// Resolve the app-server command. Discovery order (aligned with zcode-acp):
/// config.bin → env ZCODE_BIN → first existing candidate from
/// `zcode_candidate_paths`. env/exists are injected so every branch is
/// testable without touching the real host. Hosts with read IO can widen the
/// candidate list via `zcode_probe_paths` + `zcode_resolve_command_from`.
pub fn zcode_resolve_command(
  config~ : ZcodeConfig,
  env~ : (String) -> String?,
  exists~ : (String) -> Bool,
) -> Result[(String, Array[String]), ZcodeError] {
  match zcode_trusted_bin(config~, env~) {
    Some(b) => zcode_command_for(config~, env~, b)
    None =>
      zcode_resolve_command_from(
        config~,
        env~,
        candidates=zcode_candidate_paths(config~, env~),
        exists~,
      )
  }
}

///|
/// Detect-and-build in one async step for hosts whose only existence probe
/// is async: every static candidate from `zcode_candidate_paths` is probed
/// once up front (a raising probe counts as missing) into a memo that feeds
/// `zcode_resolve_command`'s sync `exists` seam. A miss degrades to None
/// instead of an error. Detection stays static-only because the seam has no
/// read/list capability — the .desktop and symlink tiers live in
/// `zcode_probe_paths` for hosts that can read (the backend pre-probes do).
pub async fn zcode_ext_if_detected(
  config? : ZcodeConfig = zcode_config(),
  env~ : (String) -> String?,
  exists~ : async (String) -> Bool,
) -> ZcodeExt? {
  let memo : Map[String, Bool] = Map::from_array([])
  let candidates = zcode_candidate_paths(config~, env~)
  for path in candidates {
    memo[path] = exists(path) catch { _ => false }
  }
  match
    zcode_resolve_command(config~, env~, exists=fn(path : String) {
      memo.get(path).unwrap_or(false)
    }) {
    Ok(_) => Some(zcode_ext(config~))
    Err(_) => None
  }
}

///|
/// v2 credentials path: config.creds_path → env ZCODE_CREDS →
/// <HOME|USERPROFILE>/.zcode/v2/config.json (missing home degrades to a
/// root-relative path, which then fails unreadably downstream).
pub fn zcode_creds_path(
  config~ : ZcodeConfig,
  env~ : (String) -> String?,
) -> String {
  match config.creds_path {
    Some(p) => p
    None =>
      match env("ZCODE_CREDS") {
        Some(p) => p
        None => {
          let home = match zcode_home_of(env~) {
            Some(h) => h
            None => ""
          }
          home + "/.zcode/v2/config.json"
        }
      }
  }
}
