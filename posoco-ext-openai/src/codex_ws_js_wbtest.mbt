///|
/// Reentrant mock install: async tests interleave at await points, so the
/// registry is created once with a monotonic handle sequence (never reset —
/// a reset would collide handles across concurrent tests) and the mock
/// WebSocket class is installed once for the process. Restore only clears
/// the installing test's tracked timers.
extern "js" fn ws_test_install() -> () -> Unit =
  #| () => {
  #|   (globalThis.__posocoWs ||= { seq: 0, sockets: new Map() });
  #|   const timers = (globalThis.__posocoWsTestTimers ||= []);
  #|   if (!globalThis.__posocoMockWebSocket) {
  #|     globalThis.__posocoMockWebSocket = class extends EventTarget {
  #|       constructor() { super(); queueMicrotask(() => this.dispatchEvent(new Event("open"))); }
  #|       send() {}
  #|       close() { this.dispatchEvent(new Event("close")); }
  #|     };
  #|     globalThis.WebSocket = globalThis.__posocoMockWebSocket;
  #|   }
  #|   return () => {
  #|     for (const timer of timers) clearTimeout(timer);
  #|     timers.length = 0;
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

///|
/// Frames that arrive while no reader is pending (the pump's pause window)
/// must survive a close: the usage-limit error frame precedes the close, and
/// dropping it turns a typed RateLimited into a plain transport failure.
async test "close drains buffered frames before EOF" {
  let restore = ws_test_install()
  defer restore()
  let handle = ws_js_open("ws://fixture", "{}").wait()
  defer ws_js_close(handle)
  let controller = @js_async.AbortController::new()
  // Healthy path: waiter pending, the frame resolves it.
  let first = ws_js_next(handle, controller.signal(), 1000)
  ws_test_text(handle, "{\"first\":true}")
  assert_eq(first.wait(), Some("{\"first\":true}"))
  // No-waiter window: the error frame can only buffer.
  ws_test_text(
    handle, "{\"type\":\"error\",\"error\":{\"message\":\"usage limit reached\"}}",
  )
  // Close fires before the pump reads again.
  ws_test_emit(handle, "close")
  let second = ws_js_next(handle, controller.signal(), 1000)
  match second.wait() {
    Some(text) => assert_true(text.contains("usage limit"))
    None => fail("close discarded the buffered error frame")
  }
  // After the drain, a closed socket reads as EOF promptly (no idle wait).
  let eof = ws_js_next(handle, controller.signal(), 1000)
  let outcome = @async.with_timeout_opt(100, () => {
    eof.wait(abort_controller=controller)
  })
  assert_true(outcome is Some(None))
}

///|
/// A close that lands while a reader is pending must hand it the buffered
/// frame instead of an EOF.
async test "close resolves a pending reader with the buffered frame" {
  let restore = ws_test_install()
  defer restore()
  let handle = ws_js_open("ws://fixture", "{}").wait()
  defer ws_js_close(handle)
  let controller = @js_async.AbortController::new()
  let pending = ws_js_next(handle, controller.signal(), 1000)
  ws_test_text(handle, "{\"queued\":1}")
  ws_test_emit(handle, "close")
  assert_eq(pending.wait(), Some("{\"queued\":1}"))
}

///|
/// Multiple buffered frames drain in order, then EOF.
async test "close keeps every buffered frame in order" {
  let restore = ws_test_install()
  defer restore()
  let handle = ws_js_open("ws://fixture", "{}").wait()
  defer ws_js_close(handle)
  let controller = @js_async.AbortController::new()
  ws_test_text(handle, "{\"n\":1}")
  ws_test_text(handle, "{\"n\":2}")
  ws_test_emit(handle, "close")
  assert_eq(
    ws_js_next(handle, controller.signal(), 1000).wait(),
    Some("{\"n\":1}"),
  )
  assert_eq(
    ws_js_next(handle, controller.signal(), 1000).wait(),
    Some("{\"n\":2}"),
  )
  let eof = ws_js_next(handle, controller.signal(), 1000)
  let outcome = @async.with_timeout_opt(100, () => {
    eof.wait(abort_controller=controller)
  })
  assert_true(outcome is Some(None))
}
