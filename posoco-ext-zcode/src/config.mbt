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
/// The paths `zcode_resolve_command` probes for auto-discovery, in order:
/// every PATH entry joined with "zcode", then the platform bundle
/// candidates (darwin → windows via LOCALAPPDATA → linux via
/// ZCODE_INSTALL_DIR; each lists only when its env root is set). An
/// explicit `config.bin` or `ZCODE_BIN` is trusted without a probe, so
/// those cases yield an empty list. No compile-time platform switch: env
/// is injected, so a host simply misses the candidates that do not apply.
pub fn zcode_candidate_paths(
  config~ : ZcodeConfig,
  env~ : (String) -> String?,
) -> Array[String] {
  if config.bin is Some(_) {
    return []
  }
  if env("ZCODE_BIN") is Some(_) {
    return []
  }
  let candidates : Array[String] = []
  match env("PATH") {
    Some(path) =>
      for dir in path.split(":") {
        candidates.push(dir.to_owned() + "/zcode")
      }
    None => ()
  }
  candidates.push("/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs")
  match env("LOCALAPPDATA") {
    Some(local_app_data) =>
      candidates.push(
        local_app_data + "\\Programs\\ZCode\\resources\\glm\\zcode.cjs",
      )
    None => ()
  }
  match env("ZCODE_INSTALL_DIR") {
    Some(dir) => candidates.push(dir + "/resources/glm/zcode.cjs")
    None => ()
  }
  candidates
}

///|
/// Resolve the app-server command. Discovery order (aligned with zcode-acp):
/// config.bin → env ZCODE_BIN → first existing candidate from
/// `zcode_candidate_paths`. A ".cjs" bin gets its interpreter prefixed —
/// config.node, else env ZCODE_NODE, else "node". env/exists are injected so
/// every branch is testable without touching the real host.
pub fn zcode_resolve_command(
  config~ : ZcodeConfig,
  env~ : (String) -> String?,
  exists~ : (String) -> Bool,
) -> Result[(String, Array[String]), ZcodeError] {
  let bin = match config.bin {
    Some(b) => Some(b)
    None =>
      match env("ZCODE_BIN") {
        Some(b) => Some(b)
        None => {
          // A PATH-entry hit keeps the bare "zcode" command (the OS resolves
          // the directory at spawn time); a bundle hit runs the probed path.
          let mut bin : String? = None
          for path in zcode_candidate_paths(config~, env~) {
            if exists(path) {
              bin = Some(if path.has_suffix(".cjs") { path } else { "zcode" })
              break
            }
          }
          bin
        }
      }
  }
  match bin {
    Some(b) =>
      if b.has_suffix(".cjs") {
        let interpreter = match config.node {
          Some(n) => n
          None =>
            match env("ZCODE_NODE") {
              Some(n) => n
              None => "node"
            }
        }
        Ok((interpreter, [b, "app-server", "--stdio"]))
      } else {
        Ok((b, ["app-server", "--stdio"]))
      }
    None => Err(ZcodeBinNotFound)
  }
}

///|
/// Detect-and-build in one async step for hosts whose only existence probe
/// is async: every candidate from `zcode_candidate_paths` is probed once up
/// front (a raising probe counts as missing) into a memo that feeds
/// `zcode_resolve_command`'s sync `exists` seam. A miss degrades to None
/// instead of an error.
pub async fn zcode_ext_if_detected(
  config? : ZcodeConfig = zcode_config(),
  env~ : (String) -> String?,
  exists~ : async (String) -> Bool,
) -> ZcodeExt? {
  let memo : Map[String, Bool] = Map::from_array([])
  for path in zcode_candidate_paths(config~, env~) {
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
/// <HOME>/.zcode/v2/config.json (missing HOME degrades to a root-relative
/// path, which then fails unreadably downstream).
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
          let home = match env("HOME") {
            Some(h) => h
            None => ""
          }
          home + "/.zcode/v2/config.json"
        }
      }
  }
}
