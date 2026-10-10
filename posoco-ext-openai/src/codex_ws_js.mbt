///|
/// JS-backend WebSocket transport. Only the Bun runtime declares support:
/// Bun's WebSocket accepts handshake headers (Node's undici silently drops
/// them, which would fail authentication).
///
/// Message framing: the JS side keeps a per-connection queue of text frames;
/// `next_text` drains one frame per call through a promise (resolved by the
/// message handler, or with `None` on close/error/abort). WS message
/// boundaries are preserved as-is — server frames may be pretty-printed
/// multi-line JSON and must not be split.

///|
priv struct WsTransport {
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
  #|     const entry = { socket, queue: [], waiter: null, opened: false };
  #|     registry.sockets.set(handle, entry);
  #|     socket.addEventListener("message", (event) => {
  #|       const frame = String(event.data);
  #|       if (entry.waiter) {
  #|         const waiter = entry.waiter;
  #|         entry.waiter = null;
  #|         if (waiter.timer) clearTimeout(waiter.timer);
  #|         waiter.resolve(frame);
  #|       } else {
  #|         entry.queue.push(frame);
  #|       }
  #|     });
  #|     const finish = () => {
  #|       if (entry.waiter) {
  #|         const waiter = entry.waiter;
  #|         entry.waiter = null;
  #|         waiter.resolve(null);
  #|       }
  #|       entry.queue.length = 0;
  #|     };
  #|     socket.addEventListener("open", () => {
  #|       entry.opened = true;
  #|       resolve(handle);
  #|     });
  #|     socket.addEventListener("error", () => {
  #|       if (!entry.opened) {
  #|         registry.sockets.delete(handle);
  #|         resolve(-1);
  #|       } else {
  #|         finish();
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
/// Two minutes without any frame — server frames or pings both refresh it —
/// marks the connection dead. Long enough for slow first tokens, short
/// enough that a silently dropped socket recovers into the SSE fallback.
const WS_IDLE_TIMEOUT_MS : Int = 120_000

///|
/// Next text frame; `null` resolves on close/error (stream end) and `""` on
/// idle timeout (a server frame is never empty, so the sentinel is
/// unambiguous). The abort signal is honored so a cancelled pump never waits
/// on a silent socket. The idle timeout is the dead-connection escape: a
/// server that accepts frames but stops answering would otherwise hold the
/// pump forever.
extern "js" fn ws_js_next(
  handle : Int,
  signal : @js_async.AbortSignal,
  idle_timeout_ms : Int,
) -> @js_async.Promise[String?] =
  #| (handle, signal, idleTimeoutMs) => new Promise((resolve) => {
  #|   const registry = globalThis.__posocoWs;
  #|   const entry = registry && registry.sockets.get(handle);
  #|   if (!entry) return resolve(null);
  #|   if (entry.queue.length > 0) return resolve(entry.queue.shift());
  #|   let done = false;
  #|   const finish = (value) => {
  #|     if (done) return;
  #|     done = true;
  #|     if (value === "" && entry.waiter && entry.waiter.timer) clearTimeout(entry.waiter.timer);
  #|     entry.waiter = null;
  #|     resolve(value);
  #|   };
  #|   const timer = setTimeout(() => {
  #|     try { entry.socket.close(); } catch {}
  #|     finish("");
  #|   }, idleTimeoutMs);
  #|   entry.waiter = { resolve: finish, timer };
  #|   signal.addEventListener("abort", () => finish(null), { once: true });
  #| })

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
/// Serialize headers for the JS handshake (Bun's WebSocket `headers` option).
fn codex_ws_headers_json(headers : @http.Headers) -> String {
  let object : Map[String, Json] = Map::from_array([])
  for key, value in headers {
    object[key.to_string()] = Json::string(value)
  }
  Json::object(object).stringify()
}

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
  Ok({ handle, })
}

///|
async fn WsTransport::send_text(
  self : WsTransport,
  text : String,
) -> Bool noraise {
  ws_js_send(self.handle, text)
}

///|
/// Next event frame; `Ok(None)` = the connection ended. Whole frames only:
/// pretty-printed multi-line JSON arrives intact.
async fn WsTransport::next_text(
  self : WsTransport,
) -> Result[String?, String] noraise {
  let controller = @js_async.AbortController::new()
  let frame = @js_async.run_promise(fn(signal) {
    ws_js_next(self.handle, signal, WS_IDLE_TIMEOUT_MS)
  }) catch {
    _ => None
  }
  controller.abort()
  match frame {
    // Idle-timeout sentinel: surface as a transport error so the pump's
    // pre-emit path falls back to SSE instead of waiting forever.
    Some("") => Err("websocket idle timeout")
    other => Ok(other)
  }
}

///|
fn WsTransport::close(self : WsTransport) -> Unit {
  ws_js_close(self.handle)
}
