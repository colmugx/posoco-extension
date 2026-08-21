///| Minimal JS Promise bridge for the JS-only adaptor.

///|
/// Posoco itself uses moonbitlang/async; this local primitive only adapts an
/// externally-owned JavaScript Promise into the active MoonBit coroutine.
pub(all) suberror JsPromiseError {
  Rejected(String)
}

///|
async fn[X] suspend_js_promise(
  register : ((X) -> Unit, (JsPromiseError) -> Unit) -> Unit,
) -> X raise JsPromiseError = "%async.suspend"

///|
async fn wait_js_string(promise : JsPromise) -> String raise JsPromiseError {
  suspend_js_promise(fn(resolve, reject) {
    promise.attach_string(resolve, fn(reason) {
      reject(JsPromiseError::Rejected(reason))
    })
  })
}

///|
/// Start a top-level coroutine from a synchronous JS export.
fn run_async_detached(task : async () -> Unit noraise) -> Unit = "%async.run"
