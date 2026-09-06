///|

///|
fn kimi_hostname() -> String {
  kimi_js_hostname()
}

///|
fn kimi_os_version() -> String {
  kimi_js_os_release()
}

///|
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
