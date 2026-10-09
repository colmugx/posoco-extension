///|
/// JS-backend WebSocket transport. Only the Bun runtime declares support:
/// Bun's WebSocket accepts handshake headers (Node's undici silently drops
/// them, which would fail authentication). Every JS failure path resolves
/// instead of throwing so the shared layer can fall back to SSE.
///
/// Message framing: the JS side pipes each text message into a
/// TransformStream followed by a newline separator (JSON never contains raw
/// newlines), and the MoonBit side reads the stream line-wise.

///|
priv struct WsTransport {
  reader : @js_async.ReadableStream
  handle : Int
}

///|
fn codex_ws_supported() -> Bool {
  ws_js_runtime_supported()
}

///|
extern "js" fn ws_js_runtime_supported() -> Bool =
  #| () => typeof Bun !== "undefined" && typeof WebSocket === "function"

///|
/// Open the socket and resolve the registry handle; `-1` means the handshake
/// failed (never rejects, so the shared layer always sees a value).
extern "js" fn ws_js_open(
  url : String,
  headers_json : String,
) -> @js_async.Promise[Int] =
  #| (url, headersJson) => new Promise((resolve) => {
  #|   try {
  #|     const registry = (globalThis.__posocoWs ||= { seq: 0, sockets: new Map() });
  #|     const socket = new WebSocket(url, { headers: JSON.parse(headersJson) });
  #|     const handle = ++registry.seq;
  #|     const ts = new TransformStream();
  #|     const entry = { socket, writer: null, opened: false, readable: ts.readable };
  #|     registry.sockets.set(handle, entry);
  #|     socket.addEventListener("open", () => {
  #|       entry.opened = true;
  #|       entry.writer = ts.writable.getWriter();
  #|       resolve(handle);
  #|     });
  #|     socket.addEventListener("message", (event) => {
  #|       if (entry.writer) {
  #|         entry.writer
  #|           .write(new TextEncoder().encode(String(event.data) + "\n"))
  #|           .catch(() => {});
  #|       }
  #|     });
  #|     const finish = () => {
  #|       if (entry.writer) {
  #|         entry.writer.close().catch(() => {});
  #|       }
  #|       registry.sockets.delete(handle);
  #|     };
  #|     socket.addEventListener("error", () => {
  #|       if (!entry.opened) {
  #|         registry.sockets.delete(handle);
  #|         resolve(-1);
  #|       }
  #|     });
  #|     socket.addEventListener("close", () => {
  #|       if (!entry.opened) {
  #|         registry.sockets.delete(handle);
  #|         resolve(-1);
  #|       } else {
  #|         finish();
  #|       }
  #|     });
  #|   } catch {
  #|     resolve(-1);
  #|   }
  #| })

///|
extern "js" fn ws_js_reader(handle : Int) -> @js_async.JsReadableStream =
  #| (handle) => {
  #|   const registry = globalThis.__posocoWs;
  #|   const entry = registry && registry.sockets.get(handle);
  #|   if (!entry) {
  #|     return new ReadableStream({ start(c) { c.close(); } });
  #|   }
  #|   return entry.readable;
  #| }

///|
extern "js" fn ws_js_send(handle : Int, text : String) -> Bool =
  #| (handle, text) => {
  #|   try {
  #|     const registry = globalThis.__posocoWs;
  #|     const entry = registry && registry.sockets.get(handle);
  #|     if (!entry) return false;
  #|     entry.socket.send(text);
  #|     return true;
  #|   } catch {
  #|     return false;
  #|   }
  #| }

///|
extern "js" fn ws_js_close(handle : Int) -> Unit =
  #| (handle) => {
  #|   try {
  #|     const registry = globalThis.__posocoWs;
  #|     const entry = registry && registry.sockets.get(handle);
  #|     if (entry) {
  #|       entry.socket.close();
  #|     }
  #|   } catch {}
  #| }

///|
async fn WsTransport::open(
  url : String,
  headers : @http.Headers,
) -> Result[WsTransport, String] noraise {
  // The extern promise never rejects; a failed handshake resolves -1.
  let handle = @js_async.run_promise(fn(_signal) {
    ws_js_open(url, codex_ws_headers_json(headers))
  }) catch {
    _ => -1
  }
  if handle < 0 {
    return Err("websocket handshake failed")
  }
  Ok({
    reader: @js_async.ReadableStream::from_js(ws_js_reader(handle)),
    handle,
  })
}

///|
async fn WsTransport::send_text(
  self : WsTransport,
  text : String,
) -> Bool noraise {
  ws_js_send(self.handle, text)
}

///|
/// Next event payload; `Ok(None)` = the connection ended (the JS side ends
/// the transform stream on close/error, which surfaces as EOF here).
async fn WsTransport::next_text(
  self : WsTransport,
) -> Result[String?, String] noraise {
  let text = self.reader.read_until("\n") catch {
    err => return Err(err.to_string())
  }
  Ok(text)
}

///|
fn WsTransport::close(self : WsTransport) -> Unit {
  self.reader.close()
  ws_js_close(self.handle)
}

///|
/// Serialize headers for the JS handshake (Bun's WebSocket `headers` option).
fn codex_ws_headers_json(headers : @http.Headers) -> String {
  let object : Map[String, Json] = Map::from_array([])
  for key, value in headers {
    object[key.to_string()] = Json::string(value)
  }
  Json::object(object).stringify()
}
