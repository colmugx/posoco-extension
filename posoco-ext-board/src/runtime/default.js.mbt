///|
pub struct UnsupportedBoardWebServer {}

///|
pub fn UnsupportedBoardWebServer::UnsupportedBoardWebServer() -> UnsupportedBoardWebServer {
  UnsupportedBoardWebServer::{ }
}

///|
pub impl BoardWebServer for UnsupportedBoardWebServer with fn bind(_self) {
  Err("posoco-ext-board S1 local control plane is native-only")
}

///|
pub impl BoardWebServer for UnsupportedBoardWebServer with fn run(_self) {
  Err("posoco-ext-board S1 local control plane is native-only")
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
pub struct UnsupportedBrowserOpener {}

///|
pub impl BrowserOpener for UnsupportedBrowserOpener with fn open(_self, _url) {
  Err("posoco-ext-board S1 browser opener is native-only")
}

///|
pub fn default_board_runtime(
  event_buffer : Int,
  client_queue_depth? : Int = 256,
) -> BoardRuntime {
  let server = UnsupportedBoardWebServer::UnsupportedBoardWebServer()
  let opener = UnsupportedBrowserOpener::{ }
  let hub = BoardEventHub(capacity=event_buffer, client_queue_depth~)
  BoardRuntime::with_adapters(hub~, server~, opener~)
}

///|
pub extend UnsupportedBoardWebServer with BoardWebServer::{
  bind,
  run,
  browser_url,
  close,
  is_alive,
  last_error,
}

///|
pub extend UnsupportedBrowserOpener with BrowserOpener::{open}
