///|
// node:fs sync APIs bound with `#module` and injected into the inline-JS
// wrappers as values (pattern follows posoco-ext-workspace fs_port.js.mbt /
// moonbitlang/x/fs/fs_js.mbt); FFI stays on the proven stable boundaries
// (docs/questions.md 2026-08-19): pure value pass-through and typed
// ok/content result objects.

///|
/// `process.env[name] ?? ""` — pure value pass-through. Blank and missing
/// collapse here; NmemConfig::resolve treats blank as missing anyway, so the
/// shared `String?` wrapper below loses nothing.
extern "js" fn js_env_raw(name : String) -> String =
  #| (name) => process.env[name] ?? ""

///|
/// js env lookup for the shared platform surface. Home-directory resolution
/// on js goes through `process.env.HOME` (Windows hosts are a documented v1
/// limitation, plan D7).
pub fn runner_get_env(name : String) -> String? {
  let raw = js_env_raw(name)
  if raw == "" {
    None
  } else {
    Some(raw)
  }
}

///|
/// Opaque ok/content results: "" cannot double as a failure sentinel
/// (empty home files are valid content).
#external
priv type JsTextResult

///|
#external
priv type JsWriteResult

///|
extern "js" fn JsTextResult::is_ok(self : Self) -> Bool =
  #| (res) => res.ok

///|
extern "js" fn JsTextResult::content(self : Self) -> String =
  #| (res) => res.content

///|
extern "js" fn JsWriteResult::is_ok(self : Self) -> Bool =
  #| (res) => res.ok

///|
extern "js" fn JsWriteResult::content(self : Self) -> String =
  #| (res) => res.content

///|
#module("node:fs")
extern "js" fn fs_read_text_sync(path : String, encoding : String) -> String = "readFileSync"

///|
#module("node:fs")
extern "js" fn fs_write_file_sync(path : String, content : String) -> Unit = "writeFileSync"

///|
/// mkdirSync's 2nd argument is a JS options object, so the declared 2nd
/// parameter is only a value-passing shape; the wrapper builds
/// `{ recursive: true }` on the JS side.
#module("node:fs")
extern "js" fn fs_mkdir_sync(path : String, recursive : Bool) -> Unit = "mkdirSync"

///|
extern "js" fn js_read_home_text(
  read_text : (String, String) -> String,
  path : String,
) -> JsTextResult =
  #| (readFile, path) => {
  #|   try {
  #|     return { ok: true, content: readFile(path, "utf8") };
  #|   } catch (error) {
  #|     return { ok: false, content: String(error?.message ?? error) };
  #|   }
  #| }

///|
extern "js" fn js_write_home_file(
  write_file : (String, String) -> Unit,
  path : String,
  content : String,
) -> JsWriteResult =
  #| (writeFile, path, content) => {
  #|   try { writeFile(path, content); return { ok: true, content: "" }; }
  #|   catch (error) { return { ok: false, content: String(error?.message ?? error) }; }
  #| }

///|
/// `fs.mkdirSync(dir, { recursive: true })` wrapped so a failure degrades to
/// a no-op (an existing directory is the normal case; the write below
/// surfaces real problems itself). Synchronous node:fs is a Bun builtin.
extern "js" fn js_mkdir_p(mkdir : (String, Bool) -> Unit, dir : String) -> Unit =
  #| (mkdir, dir) => { try { mkdir(dir, { recursive: true }); } catch (e) {} }

///|
/// js `NmemPlatform`: home files through node:fs (#module bindings).
pub(all) struct PlatformFs {
  // empty
}

///|
pub fn PlatformFs::PlatformFs() -> PlatformFs {
  PlatformFs::{ }
}

///|
fn home_path(rel : String) -> String? {
  match runner_get_env("HOME") {
    None => None
    Some(home) => Some(home + "/" + rel)
  }
}

///|
pub impl NmemPlatform for PlatformFs with fn read_home_file(
  _self : PlatformFs,
  rel : String,
) -> String? {
  match home_path(rel) {
    None => None
    Some(path) => {
      let res = js_read_home_text(fs_read_text_sync, path)
      if res.is_ok() {
        Some(res.content())
      } else {
        None
      }
    }
  }
}

///|
pub impl NmemPlatform for PlatformFs with fn write_home_file(
  _self : PlatformFs,
  rel : String,
  content : String,
) -> Result[Unit, String] {
  match home_path(rel) {
    None => Err("HOME is not set; cannot persist the Nowledge Mem config")
    Some(path) => {
      let dir = match path.rev_find("/") {
        Some(at) => path[:at].to_owned()
        None => path
      }
      js_mkdir_p(fs_mkdir_sync, dir)
      let res = js_write_home_file(fs_write_file_sync, path, content)
      if res.is_ok() {
        Ok(())
      } else {
        Err(res.content())
      }
    }
  }
}

///|
pub extend PlatformFs with NmemPlatform::{read_home_file, write_home_file}
