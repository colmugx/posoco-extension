///|
pub struct UnsupportedBoardWebServer {}

///|
pub fn UnsupportedBoardWebServer::UnsupportedBoardWebServer() -> UnsupportedBoardWebServer {
  UnsupportedBoardWebServer::{ }
}

///|
pub impl BoardWebServer for UnsupportedBoardWebServer with fn bind(_self) {
  Err("standalone Board presentation requires posoco-ext-board-native")
}

///|
pub impl BoardWebServer for UnsupportedBoardWebServer with fn run(_self) {
  Err("standalone Board presentation requires posoco-ext-board-native")
}

///|
pub impl BoardWebServer for UnsupportedBoardWebServer with fn browser_url(_self) {
  None
}

///|
pub impl BoardWebServer for UnsupportedBoardWebServer with fn close(_self) {
  ()
}

///|
pub impl BoardWebServer for UnsupportedBoardWebServer with fn is_alive(_self) {
  false
}

///|
pub impl BoardWebServer for UnsupportedBoardWebServer with fn last_error(_self) {
  None
}

///|
pub impl BoardWebServer for UnsupportedBoardWebServer with fn set_backend(
  _self,
  _backend : @backend.BoardBackend,
) -> Unit {
  ()
}

///|
pub struct UnsupportedBrowserOpener {}

///|
pub impl BrowserOpener for UnsupportedBrowserOpener with fn open(_self, _url) {
  Err("standalone Board browser opener requires posoco-ext-board-native")
}

///|
/// Headless default on both targets. Native standalone hosts compose the
/// MoonBack adapter from `posoco-ext-board-native` instead.
pub fn default_board_runtime(
  event_buffer : Int,
  client_queue_depth? : Int = 256,
) -> BoardRuntime {
  let backend = @backend.BoardBackend::BoardBackend(
    event_buffer~,
    client_queue_depth~,
  )
  let server = UnsupportedBoardWebServer::UnsupportedBoardWebServer()
  let opener = UnsupportedBrowserOpener::{ }
  BoardRuntime::with_adapters(backend~, server~, opener~)
}

///|
pub extend UnsupportedBoardWebServer with BoardWebServer::{
  bind,
  run,
  browser_url,
  close,
  is_alive,
  last_error,
  set_backend,
}

///|
pub extend UnsupportedBrowserOpener with BrowserOpener::{open}
