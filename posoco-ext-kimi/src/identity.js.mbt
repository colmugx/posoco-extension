// js platform probes for the Kimi provider identity. node:os and
// node:child_process members are bound with `#module` and injected into the
// inline-JS wrappers as values (pattern follows posoco-ext-workspace
// fs_port.js.mbt / moonbitlang/x/fs/fs_js.mbt); failures degrade to "" and
// the callers fall back to "unknown" so header values are never blank.

///|
#module("node:os")
extern "js" fn os_hostname() -> String = "hostname"

///|
#module("node:os")
extern "js" fn os_release() -> String = "release"

///|
/// execFileSync's real signature takes a JS options object; the declared
/// 2nd parameter is only a value-passing shape, and the wrapper passes the
/// literal args array plus `{ encoding, timeout }`.
#module("node:child_process")
extern "js" fn exec_file_sync(
  file : String,
  args : FixedArray[String],
) -> String = "execFileSync"

///|
fn kimi_hostname() -> String {
  kimi_js_hostname(os_hostname)
}

///|
fn kimi_os_version() -> String {
  kimi_js_os_release(os_release)
}

///|
fn kimi_device_model() -> String {
  kimi_js_device_model(os_release, exec_file_sync)
}

///|
extern "js" fn kimi_js_hostname(hostname : () -> String) -> String =
  #| (hostname) => {
  #|   try { return hostname() || ''; } catch { return ''; }
  #| }

///|
extern "js" fn kimi_js_os_release(release : () -> String) -> String =
  #| (release) => {
  #|   try { return release() || ''; } catch { return ''; }
  #| }

///|
extern "js" fn kimi_js_device_model(
  release : () -> String,
  exec_sync : (String, FixedArray[String]) -> String,
) -> String =
  #| (release, execSync) => {
  #|   const platform = process.platform;
  #|   const arch = process.arch;
  #|   let productVersion = '';
  #|   try { productVersion = release() || ''; } catch {}
  #|   if (platform === 'darwin') {
  #|     try {
  #|       const v = execSync('/usr/bin/sw_vers', ['-productVersion'], { encoding: 'utf-8', timeout: 1000 }).trim();
  #|       if (v.length > 0) productVersion = v;
  #|     } catch {}
  #|     return `macOS ${productVersion} ${arch}`;
  #|   }
  #|   if (platform === 'win32') return `Windows ${productVersion} ${arch}`;
  #|   return `${platform} ${productVersion} ${arch}`.trim();
  #| }
