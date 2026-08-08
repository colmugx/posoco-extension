///|
/// JS-backend implementations of the host identity probes used by
/// `kimi_default_headers`. Mirrors `packages/oauth/src/identity.ts` from
/// MoonshotAI/kimi-code: `os.hostname()` / `os.release()` and a Darwin-aware
/// `deviceModel()` that prefers `sw_vers -productVersion` over the kernel
/// release. Runs under Bun or Node (cetas-js host environment).

///|
/// Hostname reported by the OS, or "" when unavailable.
fn kimi_hostname() -> String {
  kimi_js_hostname()
}

///|
/// OS release string (kernel version on Unix), or "".
fn kimi_os_version() -> String {
  kimi_js_os_release()
}

///|
/// Human-readable device model. On Darwin this is `macOS <productVersion>
/// <arch>` (e.g. `macOS 26.2 arm64`), matching kimi-code; on other platforms
/// it falls back to `<platform> <release> <arch>`.
fn kimi_device_model() -> String {
  kimi_js_device_model()
}

///|
extern "js" fn kimi_js_hostname() -> String =
  #| () => {
  #|   try { return require('os').hostname() || ''; } catch { return ''; }
  #| }

///|
extern "js" fn kimi_js_os_release() -> String =
  #| () => {
  #|   try { return require('os').release() || ''; } catch { return ''; }
  #| }

///|
extern "js" fn kimi_js_device_model() -> String =
  #| () => {
  #|   const os = require('os');
  #|   const platform = process.platform;
  #|   const arch = process.arch;
  #|   const release = os.release();
  #|   if (platform === 'darwin') {
  #|     let productVersion = release;
  #|     try {
  #|       const { execFileSync } = require('child_process');
  #|       const v = execFileSync('/usr/bin/sw_vers', ['-productVersion'], { encoding: 'utf-8', timeout: 1000 }).trim();
  #|       if (v.length > 0) productVersion = v;
  #|     } catch {}
  #|     return `macOS ${productVersion} ${arch}`;
  #|   }
  #|   if (platform === 'win32') return `Windows ${release} ${arch}`;
  #|   return `${platform} ${release} ${arch}`.trim();
  #| }
