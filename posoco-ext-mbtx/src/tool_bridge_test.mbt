///|
struct EchoInvoker {
  calls : Array[String]
}

///|
impl @posoco-ext-mbtx.ToolInvoker for EchoInvoker with fn invoke(
  self,
  name,
  arguments,
) {
  self.calls.push(name)
  if arguments is { "value": 1, .. } {
    @async.sleep(20)
  }
  @protocol.Success(content=name, structured=Some(arguments))
}

///|
async test "concurrent guest requests remain correlated and are constrained by capability" {
  let runtime = test_runtime()
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    let source =
      #|async fn run(ctx : @sdk.Context, input : Json) -> @sdk.Outcome {
      #|  let results = @async.all([
      #|    () => ctx.call("read", {"value": 1}),
      #|    () => ctx.call("read", {"value": 2}),
      #|  ])
      #|  let denied = ctx.call("write", {})
      #|  match (results[0], results[1], denied) {
      #|    (@sdk.Outcome::Success(structured=Some(a), ..), @sdk.Outcome::Success(structured=Some(b), ..), @sdk.Outcome::Failure(code="CapabilityDenied", ..)) =>
      #|      @sdk.Outcome::Success(content="joined", structured=Some({"first": a, "second": b}))
      #|    _ => @sdk.Outcome::Failure(code="Unexpected", content="unexpected outcomes", structured=None)
      #|  }
      #|}
    // Test double only: this is not a Posoco governance adapter.
    let invoker = EchoInvoker::{ calls: [], }
    let artifact = runtime.build(source)
    let result = runtime.run(
      artifact,
      {},
      invocation_id="join",
      tools=["read"],
      invoker~,
    )
    assert_eq(
      result.outcome,
      @protocol.Success(
        content="joined",
        structured=Some({ "first": { "value": 1 }, "second": { "value": 2 } }),
      ),
    )
    assert_eq(invoker.calls, ["read", "read"])
  }) catch {
    @posoco-ext-mbtx.RuntimeError::BuildFailed(message) => fail(message)
    error => raise error
  }
}

///|
async test "missing Posoco capability is an explicit outcome, not a provider bypass" {
  let runtime = test_runtime()
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    let source =
      #|async fn run(ctx : @sdk.Context, input : Json) -> @sdk.Outcome {
      #|  ctx.call("read", input)
      #|}
    let artifact = runtime.build(source)
    let result = runtime.run(artifact, {}, invocation_id="unavailable", tools=[
      "read",
    ])
    assert_true(
      result.outcome is @protocol.Failure(code="ToolInvocationUnavailable", ..),
    )
    let denied = runtime.run(artifact, {}, invocation_id="denied")
    assert_true(
      denied.outcome is @protocol.Failure(code="CapabilityDenied", ..),
    )
  }) catch {
    @posoco-ext-mbtx.RuntimeError::BuildFailed(message) => fail(message)
    error => raise error
  }
}
