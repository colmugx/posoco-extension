///|
struct BlockingInvoker {
  entered : @aqueue.Queue[Unit]
  mut settled : Bool
}

///|
impl @posoco-ext-mbtx.ToolInvoker for BlockingInvoker with fn invoke(
  self,
  _name,
  _arguments,
) {
  @async.with_task_group(group => {
    group.add_defer(() => self.settled = true)
    self.entered.put(())
    @async.sleep(60000)
    @protocol.Success(content="unexpected completion", structured=None)
  })
}

///|
async test "cancellation joins pending calls and the same invocation id can be retried" {
  let runtime = test_runtime()
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    let source =
      #|async fn run(ctx : @sdk.Context, input : Json) -> @sdk.Outcome {
      #|  ctx.call("read", input)
      #|}
    let artifact = test_program(group, source)
    let invoker = BlockingInvoker::{
      entered: @aqueue.Queue(kind=Blocking(1)),
      settled: false,
    }
    let call = group.spawn(allow_failure=true, () => {
      runtime.run_file(
        artifact,
        {},
        invocation_id="retry",
        tools=["read"],
        invoker~,
      )
    })
    @async.with_timeout(5000, () => invoker.entered.get())
    let cancellation_started = @async.now()
    assert_true(runtime.cancel("retry"))
    assert_true(runtime.cancel("retry"))
    try call.wait() catch {
      @posoco-ext-mbtx.RuntimeError::Cancelled => ()
      error => raise error
    } noraise {
      _ => fail("cancelled invocation returned success")
    }
    assert_true(@async.now() - cancellation_started < 3000L)
    assert_true(invoker.settled)
    assert_false(runtime.cancel("retry"))
    let retry = runtime.run_file(
      artifact,
      { "value": 2 },
      invocation_id="retry",
      tools=["read"],
      invoker=EchoInvoker::{ calls: [], },
    )
    assert_eq(
      retry.outcome,
      @protocol.Success(content="read", structured=Some({ "value": 2 })),
    )
  }) catch {
    @posoco-ext-mbtx.RuntimeError::BuildFailed(message) => fail(message)
    error => raise error
  }
}

///|
async test "wall clock timeout does not close the runtime" {
  let runtime = test_runtime()
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    let source =
      #|async fn run(_ctx : @sdk.Context, input : Json) -> @sdk.Outcome {
      #|  if input != Json::boolean(true) { @async.sleep(60000) }
      #|  @sdk.Outcome::Success(content="done", structured=None)
      #|}
    let artifact = test_program(group, source)
    let timeout_started = @async.now()
    try
      runtime.run_file(
        artifact,
        Json::boolean(false),
        invocation_id="timeout",
        timeout_ms=100,
      )
    catch {
      @posoco-ext-mbtx.RuntimeError::TimedOut("invocation") => ()
      error => raise error
    } noraise {
      _ => fail("expected invocation timeout")
    }
    assert_true(@async.now() - timeout_started < 3000L)
    let result = runtime.run_file(
      artifact,
      Json::boolean(true),
      invocation_id="timeout",
    )
    assert_eq(
      result.outcome,
      @protocol.Success(content="done", structured=None),
    )
  }) catch {
    @posoco-ext-mbtx.RuntimeError::BuildFailed(message) => fail(message)
    error => raise error
  }
}
