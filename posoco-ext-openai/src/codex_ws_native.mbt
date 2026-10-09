///|
/// Native backend WebSocket transport over moonbitlang/async's RFC 6455
/// client (handshake with custom headers, message-framed reads).

///|
priv struct WsTransport {
  conn : @websocket.Conn
}

///|
fn codex_ws_supported() -> Bool {
  true
}

///|
async fn WsTransport::open(
  url : String,
  headers : @http.Headers,
) -> Result[WsTransport, String] noraise {
  let conn = @websocket.Conn::connect(url, headers~) catch {
    err => return Err(err.to_string())
  }
  Ok({ conn, })
}

///|
async fn WsTransport::send_text(
  self : WsTransport,
  text : String,
) -> Bool noraise {
  let mut sent = true
  self.conn.send_text(text) catch {
    _ => sent = false
  }
  sent
}

///|
/// Next event payload; `Ok(None)` = the connection ended.
async fn WsTransport::next_text(
  self : WsTransport,
) -> Result[String?, String] noraise {
  let message = self.conn.recv() catch {
    @websocket.ConnectionClosed(_, _) => return Ok(None)
    err => return Err(err.to_string())
  }
  let data = message.read_all() catch { err => return Err(err.to_string()) }
  let text = data.text() catch { err => return Err(err.to_string()) }
  Ok(Some(text))
}

///|
fn WsTransport::close(self : WsTransport) -> Unit {
  self.conn.close()
}
