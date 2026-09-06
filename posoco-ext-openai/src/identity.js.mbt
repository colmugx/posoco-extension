///|
/// JS-backend platform probes (Bun/Node host). The externs return "" on
/// failure; the wrappers fall back to "unknown" so header values are never
/// blank.

///|
fn identity_platform() -> String {
  let platform = identity_js_platform()
  if platform.length() > 0 {
    platform
  } else {
    "unknown"
  }
}

///|
fn identity_os_release() -> String {
  let release = identity_js_os_release()
  if release.length() > 0 {
    release
  } else {
    "unknown"
  }
}

///|
fn identity_arch() -> String {
  let arch = identity_js_arch()
  if arch.length() > 0 {
    arch
  } else {
    "unknown"
  }
}

///|
extern "js" fn identity_js_platform() -> String =
  #| () => {
  #|   try { return process.platform || ''; } catch { return ''; }
  #| }

///|
extern "js" fn identity_js_os_release() -> String =
  #| () => {
  #|   try { return require('os').release() || ''; } catch { return ''; }
  #| }

///|
extern "js" fn identity_js_arch() -> String =
  #| () => {
  #|   try { return process.arch || ''; } catch { return ''; }
  #| }
