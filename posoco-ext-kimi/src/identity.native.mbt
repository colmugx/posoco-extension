///|
/// Native-backend host identity probes, backed by identity_stub.c.
///
/// The C stubs return fresh `Bytes` (UTF-8); we decode lossily here so any
/// non-UTF-8 byte from a hostile `uname` cannot break header construction.
/// On failure the stub returns an empty buffer and `kimi_ascii_header` falls
/// back to "unknown", so a header value is never silently blank.

///|
extern "c" fn kimi_native_hostname() -> Bytes = "kimi_native_hostname"

///|
extern "c" fn kimi_native_os_release() -> Bytes = "kimi_native_os_release"

///|
extern "c" fn kimi_native_macos_product_version() -> Bytes = "kimi_native_macos_product_version"

///|
extern "c" fn kimi_native_arch() -> Bytes = "kimi_native_arch"

///|
extern "c" fn kimi_native_sysname() -> Bytes = "kimi_native_sysname"

///|
fn kimi_hostname() -> String {
  @utf8.decode_lossy(kimi_native_hostname())
}

///|
fn kimi_os_version() -> String {
  @utf8.decode_lossy(kimi_native_os_release())
}

///|
/// Human-readable device model. On Darwin: `macOS <sw_vers -productVersion>
/// <arch>` (falling back to the kernel release when sw_vers is unavailable),
/// matching kimi-code's `deviceModel()`. On other platforms:
/// `<sysname> <release> <arch>`.
fn kimi_device_model() -> String {
  let sysname = @utf8.decode_lossy(kimi_native_sysname())
  let arch = @utf8.decode_lossy(kimi_native_arch())
  let release = @utf8.decode_lossy(kimi_native_os_release())
  if sysname == "Darwin" {
    let product_version = @utf8.decode_lossy(
      kimi_native_macos_product_version(),
    )
    let version = if product_version.length() > 0 {
      product_version
    } else {
      release
    }
    "macOS " + version + " " + arch
  } else {
    (sysname + " " + release + " " + arch).trim().to_owned()
  }
}
