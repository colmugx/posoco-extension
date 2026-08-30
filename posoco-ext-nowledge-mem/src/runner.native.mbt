///|
/// Native env lookup. `moonbitlang/x/sys`'s `get_env_var` is deprecated in
/// favour of `moonbitlang/core/env` (plan R4); the semantics are identical,
/// the replacement is adopted directly.
pub fn runner_get_env(name : String) -> String? {
  @env.get_env_var(name)
}

///|
/// Native `NmemPlatform`: home files via `moonbitlang/async/fs`.
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
      let data = @fs.read_file(path) catch { _ => return None }
      let text = data.text() catch { _ => return None }
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
      // The parent directory may not exist on a fresh machine; recursive
      // mkdir over an existing directory is not an error worth failing on.
      let dir = match path.rev_find("/") {
        Some(at) => path[:at].to_owned()
        None => path
      }
      @fs.mkdir(dir, recursive=true) catch {
        _ => ()
      }
      @fs.write_file(path, content) catch {
        err => return Err(err.to_string())
      }
      Ok(())
    }
  }
}
