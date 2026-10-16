///|
extern "js" fn ws_test_install() -> () -> Unit =
  #| () => {
  #|   const previous = globalThis.WebSocket;
  #|   const registry = globalThis.__posocoWs;
  #|   globalThis.__posocoWs = { seq: 0, sockets: new Map() };
  #|   const timers = [];
  #|   globalThis.__posocoWsTestTimers = timers;
  #|   globalThis.WebSocket = class extends EventTarget {
  #|     constructor() { super(); queueMicrotask(() => this.dispatchEvent(new Event("open"))); }
  #|     send() {}
  #|     close() { this.dispatchEvent(new Event("close")); }
  #|   };
  #|   return () => {
  #|     for (const timer of timers) clearTimeout(timer);
  #|     globalThis.WebSocket = previous;
  #|     globalThis.__posocoWs = registry;
  #|     delete globalThis.__posocoWsTestTimers;
  #|   };
  #| }

///|
extern "js" fn ws_test_emit(handle : Int32, kind : String) -> Unit =
  #| (handle, kind) => {
  #|   const entry = globalThis.__posocoWs.sockets.get(handle);
  #|   if (entry.waiter) globalThis.__posocoWsTestTimers.push(entry.waiter.timer);
  #|   entry.socket.dispatchEvent(new Event(kind));
  #| }

///|
extern "js" fn ws_test_remember_timer(handle : Int32) -> Unit =
  #| (handle) => {
  #|   const entry = globalThis.__posocoWs.sockets.get(handle);
  #|   if (entry?.waiter) globalThis.__posocoWsTestTimers.push(entry.waiter.timer);
  #| }

///|
extern "js" fn ws_test_text(handle : Int32, text : String) -> Unit =
  #| (handle, text) => {
  #|   const entry = globalThis.__posocoWs.sockets.get(handle);
  #|   if (entry.waiter) globalThis.__posocoWsTestTimers.push(entry.waiter.timer);
  #|   entry.socket.dispatchEvent(new MessageEvent("message", { data: text }));
  #| }

///|
extern "js" fn ws_test_resolves_none(
  promise : @js_async.Promise[String?],
) -> @js_async.Promise[Bool] =
  #| (promise) => new Promise((resolve) => {
  #|   const timer = setTimeout(() => resolve(false), 100);
  #|   promise.then(value => { clearTimeout(timer); resolve(value === undefined); });
  #| })

///|
async test "closed JS websocket returns None instead of a null text frame" {
  let transport : WsTransport = { handle: -1, }
  guard transport.next_text() is Ok(None) else {
    fail("a closed websocket must not return Some(null) as text")
  }
}

///|
async test "JS websocket frames close error timeout and cancellation stay typed" {
  let restore = ws_test_install()
  defer restore()
  for queued in [false, true] {
    let handle = ws_js_open("ws://fixture", "{}").wait()
    defer ws_js_close(handle)
    let text = "{\n  \"text\": \"你好\"\n}"
    let controller = @js_async.AbortController::new()
    if queued {
      ws_test_text(handle, text)
    }
    let pending = ws_js_next(handle, controller.signal(), 1000)
    if !queued {
      ws_test_text(handle, text)
    }
    assert_eq(pending.wait(), Some(text))
  }
  for kind in ["close", "error"] {
    let handle = ws_js_open("ws://fixture", "{}").wait()
    let controller = @js_async.AbortController::new()
    let pending = ws_js_next(handle, controller.signal(), 1000)
    ws_test_emit(handle, kind)
    assert_true(pending.wait() is None)
    let next = ws_js_next(handle, controller.signal(), 1000)
    ws_test_remember_timer(handle)
    let outcome = @async.with_timeout_opt(100, () => {
      next.wait(abort_controller=controller)
    })
    assert_true(outcome is Some(None))
  }
  let handle = ws_js_open("ws://fixture", "{}").wait()
  let controller = @js_async.AbortController::new()
  assert_true(ws_js_next(handle, controller.signal(), 1).wait() is Some(""))
  for abort_before_read in [false, true] {
    let handle = ws_js_open("ws://fixture", "{}").wait()
    defer ws_js_close(handle)
    let controller = @js_async.AbortController::new()
    if abort_before_read {
      controller.abort()
    }
    let pending = ws_js_next(handle, controller.signal(), 1000)
    ws_test_remember_timer(handle)
    controller.abort()
    assert_true(ws_test_resolves_none(pending).wait())
  }
}
