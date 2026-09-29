///|
pub struct UnsupportedBoardWebServer {}

///|
pub fn UnsupportedBoardWebServer::UnsupportedBoardWebServer(
) -> UnsupportedBoardWebServer {
  UnsupportedBoardWebServer::{ }
}

///|
pub impl BoardWebServer for UnsupportedBoardWebServer with fn attach_event_hub(
  _self,
  _hub,
) {
  ()
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
pub fn default_board_runtime(event_buffer : Int, client_queue_depth : Int) -> BoardRuntime {
  let server = UnsupportedBoardWebServer::UnsupportedBoardWebServer()
  let opener = UnsupportedBrowserOpener::{ }
  BoardRuntime::with_adapters(event_buffer~, client_queue_depth~, server=server, opener=opener)
}

///|
pub extend UnsupportedBoardWebServer with BoardWebServer::{
  attach_event_hub,
  bind,
  run,
  browser_url,
  close,
  is_alive,
  last_error,
}

///|
pub extend UnsupportedBrowserOpener with BrowserOpener::{open}
