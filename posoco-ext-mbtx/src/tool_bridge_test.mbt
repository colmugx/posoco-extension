///|
struct EchoInvoker {
  calls : Array[String]
}

///|
/// Test double that records call names; sleeps on `{"value":1}` so a
/// concurrent request can overtake it.
async fn EchoInvoker::invoke(
  self : EchoInvoker,
  name : String,
  arguments : Json,
) -> @protocol.Outcome {
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
    let artifact = test_program(group, source)
    let result = runtime.run_file(
      artifact,
      {},
      invocation_id="join",
      tools=["read"],
      on_call=(name, args) => invoker.invoke(name, args),
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
/// Test double that completes calls in the reverse order they were made, so
/// host replies reach the guest out of request order.
struct ReversedInvoker {
  calls : Array[String]
}

///|
async fn ReversedInvoker::invoke(
  self : ReversedInvoker,
  name : String,
  arguments : Json,
) -> @protocol.Outcome {
  self.calls.push(name)
  if arguments is { "value": 1, .. } {
    @async.sleep(90)
  }
  if arguments is { "value": 2, .. } {
    @async.sleep(40)
  }
  @protocol.Success(content=name, structured=Some(arguments))
}

///|
async test "concurrent out-of-order replies stay correlated per request" {
  let runtime = test_runtime()
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    let source =
      #|async fn run(ctx : @sdk.Context, _input : Json) -> @sdk.Outcome {
      #|  let results = @async.all([
      #|    () => ctx.call("read", {"value": 1}),
      #|    () => ctx.call("read", {"value": 2}),
      #|    () => ctx.call("read", {"value": 3}),
      #|  ])
      #|  match (results[0], results[1], results[2]) {
      #|    (@sdk.Outcome::Success(structured=Some(a), ..),
      #|     @sdk.Outcome::Success(structured=Some(b), ..),
      #|     @sdk.Outcome::Success(structured=Some(c), ..)) =>
      #|      @sdk.Outcome::Success(
      #|        content="joined",
      #|        structured=Some({"first": a, "second": b, "third": c}),
      #|      )
      #|    _ =>
      #|      @sdk.Outcome::Failure(
      #|        code="Unexpected",
      #|        content="unexpected outcomes",
      #|        structured=None,
      #|      )
      #|  }
      #|}
    let invoker = ReversedInvoker::{ calls: [], }
    let artifact = test_program(group, source)
    let result = runtime.run_file(
      artifact,
      {},
      invocation_id="reversed",
      tools=["read"],
      on_call=(name, args) => invoker.invoke(name, args),
    )
    assert_eq(
      result.outcome,
      @protocol.Success(
        content="joined",
        structured=Some({
          "first": { "value": 1 },
          "second": { "value": 2 },
          "third": { "value": 3 },
        }),
      ),
    )
    assert_eq(invoker.calls.length(), 3)
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
    let artifact = test_program(group, source)
    let result = runtime.run_file(artifact, {}, invocation_id="unavailable", tools=[
      "read",
    ])
    assert_true(
      result.outcome is @protocol.Failure(code="ToolInvocationUnavailable", ..),
    )
    let denied = runtime.run_file(artifact, {}, invocation_id="denied")
    assert_true(
      denied.outcome is @protocol.Failure(code="CapabilityDenied", ..),
    )
  }) catch {
    @posoco-ext-mbtx.RuntimeError::BuildFailed(message) => fail(message)
    error => raise error
  }
}
