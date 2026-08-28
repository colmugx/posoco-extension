///|
/// Native Windows detection via the `OS` environment variable (Windows sets
/// OS=Windows_NT for every process). No FFI needed.
fn ps1_platform_is_windows() -> Bool {
  @env.get_env_var("OS") == Some("Windows_NT")
}

///|
fn ps1_platform_detail() -> String {
  match @env.get_env_var("OS") {
    Some(value) => value
    None => ""
  }
}

///|
/// Native has no cheap PATH probe; hosts on stock Windows pass
/// exe="powershell" explicitly.
fn resolve_exe(exe : String) -> String {
  exe
}
