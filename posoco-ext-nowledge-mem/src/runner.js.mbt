///|
// Bun is a global under bun: `extern "js" fn ... = #| () => Bun.xxx()` works
// without require/import (posoco-ext-bash precedent). FFI stays on the two
// proven stable boundaries (docs/questions.md 2026-08-19): pure value
// pass-through (String/Bool) and Promise bridging via `@js_async.Promise::wait`.

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
/// `Bun.file(path).text()` — Promise<String> that rejects when the file is
/// missing or unreadable; the rejection is caught by the caller.
extern "js" fn bun_file_text(path : String) -> @js_async.Promise[String] =
  #| (path) => Bun.file(path).text()

///|
/// `fs.mkdirSync(dir, { recursive: true })` wrapped so a failure degrades to
/// a no-op (an existing directory is the normal case; Bun.write surfaces
/// real problems itself). Synchronous node:fs is a Bun builtin.
extern "js" fn js_mkdir_p(dir : String) -> Unit =
  #| (dir) => { try { require("node:fs").mkdirSync(dir, { recursive: true }); } catch (e) {} }

///|
/// `Bun.write(path, content)` — Promise<number> (bytes written); the count
/// is discarded, only the rejection matters.
extern "js" fn bun_write_file(
  path : String,
  content : String,
) -> @js_async.Promise[Int] =
  #| (path, content) => Bun.write(path, content)

///|
/// js (bun) `NmemPlatform`: home files via Bun.file / Bun.write.
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
      let text = bun_file_text(path).wait() catch { _ => return None }
      Some(text)
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
      js_mkdir_p(dir)
      let written = bun_write_file(path, content).wait() catch {
        err => return Err(err.to_string())
      }
      ignore(written)
      Ok(())
    }
  }
}
