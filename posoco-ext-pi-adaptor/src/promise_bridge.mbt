///| Minimal JS Promise bridge for the JS-only adaptor.

///|
/// Posoco itself uses moonbitlang/async; this local primitive only adapts an
/// externally-owned JavaScript Promise into the active MoonBit coroutine.
pub(all) suberror JsPromiseError {
  Rejected(String)
}

///|
/// JsPromise and @js_async.Promise are both opaque wrappers of the same JS
/// Promise object, so the identity cast is sound.
fn js_promise_as_async(promise : JsPromise) -> @js_async.Promise[String] = "%identity"

///|
/// On the JS target nothing pumps moonbitlang/async's scheduler in the
/// background, so a foreign-promise wait must perform wake + reschedule
/// itself, which @js_async's Promise::wait does. A raw %async.suspend resumed
/// straight from the settling JS microtask deadlocks any caller parked inside
/// a spawned sub-coroutine (e.g. the agent turn's @async.all wave executor).
async fn wait_js_string(promise : JsPromise) -> String raise JsPromiseError {
  js_promise_as_async(promise).wait() catch {
    err => raise JsPromiseError::Rejected(err.to_string())
  }
}
