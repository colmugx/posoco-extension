///|
/// home.mbt — cross-platform user home resolution with libuv semantics
/// (what Node's `os.homedir()` gives the JS twin of a product):
///
///   Windows: USERPROFILE, then HOMEDRIVE + HOMEPATH. `HOME` is
///            deliberately ignored there: Git Bash/MSYS exports it as a
///            POSIX-style path (`/c/Users/x`, even a fake `/home/user`)
///            that a native Windows process cannot use. Do not "fix" a
///            Windows host by reading `HOME` first.
///   Unix:    HOME.
///
/// Values are trimmed; empty/whitespace-only counts as unset. `None`
/// means the environment provides no home at all.

///|
/// Resolution core over injected env values, so the platform matrix is
/// testable anywhere without mutating process env.
pub fn home_dir_from_env(
  windows~ : Bool,
  home~ : String?,
  userprofile~ : String?,
  homedrive~ : String?,
  homepath~ : String?,
) -> String? {
  match windows {
    true =>
      match trimmed_non_empty(userprofile) {
        Some(path) => Some(path)
        None =>
          match (trimmed_non_empty(homedrive), trimmed_non_empty(homepath)) {
            (Some(drive), Some(rest)) => Some(drive + rest)
            _ => None
          }
      }
    false => trimmed_non_empty(home)
  }
}

///|
/// Resolve the current process's user home directory; `None` when the
/// environment provides none. The platform comes from `@path.sep`, which
/// `moonbitlang/x/path` derives per target (C stub natively,
/// `process.platform` on js).
pub fn home_dir() -> String? {
  home_dir_from_env(
    windows=@path.sep == '\\',
    home=@env.get_env_var("HOME"),
    userprofile=@env.get_env_var("USERPROFILE"),
    homedrive=@env.get_env_var("HOMEDRIVE"),
    homepath=@env.get_env_var("HOMEPATH"),
  )
}

///|
fn trimmed_non_empty(value : String?) -> String? {
  match value {
    Some(value) => {
      let trimmed = value.trim().to_owned()
      if trimmed == "" {
        None
      } else {
        Some(trimmed)
      }
    }
    None => None
  }
}
