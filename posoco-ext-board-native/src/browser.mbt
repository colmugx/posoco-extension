///|
pub struct NativeBrowserOpener {}

///|
pub fn NativeBrowserOpener::NativeBrowserOpener() -> NativeBrowserOpener {
  NativeBrowserOpener::{ }
}

///|
async fn board_run_opener(
  command : String,
  args : Array[String],
) -> Result[Unit, String] {
  let result : Result[Int, Error] = Ok(
    @process.run(command, args.clamped_view(), no_console_window=true),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(0) => Ok(())
    Ok(code) => Err("board: browser opener '\{command}' exited with \{code}")
    Err(error) =>
      Err("board: browser opener '\{command}' failed: " + error.to_string())
  }
}

///|
pub impl BrowserOpener for NativeBrowserOpener with fn open(_self, url) {
  if @env.get_env_var("OS") == Some("Windows_NT") {
    return board_run_opener("cmd", ["/c", "start", "", url])
  }
  match board_run_opener("xdg-open", [url]) {
    Ok(_) => Ok(())
    Err(linux_error) =>
      match board_run_opener("open", [url]) {
        Ok(_) => Ok(())
        Err(mac_error) => Err(linux_error + "; fallback failed: " + mac_error)
      }
  }
}

///|
pub extend NativeBrowserOpener with BrowserOpener::{open}
