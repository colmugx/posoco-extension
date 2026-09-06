///|
/// Native-backend platform probes backed by identity_stub.c. The C stubs
/// return fresh UTF-8 `Bytes`, decoded lossily; an empty probe result falls
/// back to "unknown" so header values are never blank.

///|
extern "c" fn identity_native_sysname() -> Bytes = "identity_native_sysname"

///|
extern "c" fn identity_native_release() -> Bytes = "identity_native_release"

///|
extern "c" fn identity_native_arch() -> Bytes = "identity_native_arch"

///|
fn identity_platform() -> String {
  let sysname = @utf8.decode_lossy(identity_native_sysname()).to_lower()
  if sysname.length() > 0 {
    sysname
  } else {
    "unknown"
  }
}

///|
fn identity_os_release() -> String {
  let release = @utf8.decode_lossy(identity_native_release())
  if release.length() > 0 {
    release
  } else {
    "unknown"
  }
}

///|
fn identity_arch() -> String {
  let arch = @utf8.decode_lossy(identity_native_arch())
  if arch.length() > 0 {
    arch
  } else {
    "unknown"
  }
}
