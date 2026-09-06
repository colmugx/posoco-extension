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
/// Resolve the app-server command. Discovery order (aligned with zcode-acp):
/// config.bin → env ZCODE_BIN → "zcode" on PATH → platform bundle candidates
/// (darwin → windows → linux). A ".cjs" bin gets its interpreter prefixed —
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
          let on_path = match env("PATH") {
            Some(path) => zcode_path_has(path, exists~)
            None => false
          }
          if on_path {
            Some("zcode")
          } else {
            zcode_bundle_bin(env~, exists~)
          }
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
fn zcode_path_has(path : String, exists~ : (String) -> Bool) -> Bool {
  let mut hit = false
  for dir in path.split(":") {
    if exists(dir.to_owned() + "/zcode") {
      hit = true
    }
  }
  hit
}

///|
/// Bundle candidates tried darwin → windows → linux. No compile-time
/// platform switch: env/exists are injected, so a host simply misses the
/// candidates that do not apply to it.
fn zcode_bundle_bin(
  env~ : (String) -> String?,
  exists~ : (String) -> Bool,
) -> String? {
  let darwin = "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs"
  if exists(darwin) {
    return Some(darwin)
  }
  match env("LOCALAPPDATA") {
    Some(local_app_data) => {
      let windows = local_app_data +
        "\\Programs\\ZCode\\resources\\glm\\zcode.cjs"
      if exists(windows) {
        return Some(windows)
      }
    }
    None => ()
  }
  match env("ZCODE_INSTALL_DIR") {
    Some(dir) => {
      let linux = dir + "/resources/glm/zcode.cjs"
      if exists(linux) {
        return Some(linux)
      }
    }
    None => ()
  }
  None
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
