///|
extern "js" fn microtask_promise(value : String) -> JsPromise =
  #| (value) => Promise.resolve(value)

///|
extern "js" fn microtask_rejected_promise(reason : String) -> JsPromise =
  #| (reason) => Promise.reject(new Error(reason))

///|
async test "foreign promise wait resumes inside an @async.all wave" {
  // Mirrors the agent turn's wave executor: the wait runs in a spawned child
  // coroutine, so resuming the child must pump the scheduler for the joined
  // parent.
  let results = @async.all([() => wait_js_string(microtask_promise("wave"))])
  inspect(results[0], content="wave")
}

///|
async test "foreign promise rejection surfaces as JsPromiseError" {
  let outcome : Result[String, JsPromiseError] = Ok(
    wait_js_string(microtask_rejected_promise("boom")),
  ) catch {
    err => Err(err)
  }
  match outcome {
    Err(JsPromiseError::Rejected(reason)) =>
      assert_true(reason.contains("boom"))
    _ => fail("expected JsPromiseError::Rejected")
  }
}
