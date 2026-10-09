///|
/// Wasm/llvm backends have no WebSocket transport; the shared layer's
/// support probe keeps those targets on the SSE path. The stubs exist only
/// to satisfy the shared signatures and are never reached.
priv struct WsTransport {}

///|
fn codex_ws_supported() -> Bool {
  false
}

///|
async fn WsTransport::open(
  url : String,
  headers : @http.Headers,
) -> Result[WsTransport, String] noraise {
  let _ = url
  let _ = headers
  Err("websocket transport is not available on this target")
}

///|
async fn WsTransport::send_text(
  self : WsTransport,
  text : String,
) -> Bool noraise {
  let _ = self
  let _ = text
  false
}

///|
async fn WsTransport::next_text(
  self : WsTransport,
) -> Result[String?, String] noraise {
  let _ = self
  Err("websocket transport is not available on this target")
}

///|
fn WsTransport::close(self : WsTransport) -> Unit {
  let _ = self
  ()
}
