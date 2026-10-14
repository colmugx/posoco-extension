///|
async test "build failure does not poison a ready artifact and changed source rebuilds" {
  let runtime = test_runtime()
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    let good = runtime.build(compute_source)
    try
      runtime.build(
        "async fn run(_ctx : @sdk.Context, _input : Json) -> @sdk.Outcome { unknown_value }",
      )
    catch {
      @posoco-ext-mbtx.RuntimeError::BuildFailed(diagnostics) =>
        assert_true(diagnostics.contains("unknown_value"))
      error => raise error
    } noraise {
      _ => fail("invalid source compiled successfully")
    }
    assert_eq(runtime.build(compute_source).identity(), good.identity())
    let changed = runtime.build(
      compute_source + "\n// distinct program revision\n",
    )
    assert_true(changed.identity() != good.identity())
    runtime.clear_cache()
    try runtime.run(good, {}, invocation_id="stale") catch {
      @posoco-ext-mbtx.RuntimeError::Invalid(_) => ()
      error => raise error
    } noraise {
      _ => fail("cleared artifact remained executable")
    }
  }) catch {
    @posoco-ext-mbtx.RuntimeError::BuildFailed(message) => fail(message)
    error => raise error
  }
}

///|
async test "protocol contamination and guest failure are not successful outputs" {
  let runtime = test_runtime()
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    let noisy_source =
      #|async fn run(_ctx : @sdk.Context, _input : Json) -> @sdk.Outcome {
      #|  println("debug output is not a frame")
      #|  @sdk.Outcome::Success(content="wrong", structured=None)
      #|}
    let noisy = runtime.build(noisy_source)
    try runtime.run(noisy, {}, invocation_id="noisy") catch {
      @posoco-ext-mbtx.RuntimeError::ProtocolFailure(reason) =>
        assert_true(reason.contains("JSON"))
      error => raise error
    } noraise {
      _ => fail("unframed stdout was accepted")
    }
    let crashing = runtime.build(
      "async fn run(_ctx : @sdk.Context, _input : Json) -> @sdk.Outcome { raise Failure::Failure(\"guest failed\") }",
    )
    try runtime.run(crashing, {}, invocation_id="crash") catch {
      @posoco-ext-mbtx.RuntimeError::GuestFailure(_) => ()
      error => raise error
    } noraise {
      _ => fail("crashed guest was accepted")
    }
  }) catch {
    @posoco-ext-mbtx.RuntimeError::BuildFailed(message) => fail(message)
    error => raise error
  }
}

///|
async test "output and child call budgets fail closed without disabling later invocations" {
  let runtime = test_runtime()
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    let artifact = runtime.build(compute_source)
    try
      runtime.run(artifact, {}, invocation_id="output", max_output_bytes=8)
    catch {
      @posoco-ext-mbtx.RuntimeError::ProtocolFailure(reason) =>
        assert_true(reason.contains("output budget"))
      error => raise error
    } noraise {
      _ => fail("output budget was ignored")
    }
    let source =
      #|async fn run(ctx : @sdk.Context, _input : Json) -> @sdk.Outcome {
      #|  ignore(ctx.call("read", {}))
      #|  ctx.call("read", {})
      #|}
    let workflow = runtime.build(source)
    try
      runtime.run(
        workflow,
        {},
        invocation_id="calls",
        tools=["read"],
        invoker=EchoInvoker::{ calls: [], },
        max_calls=1,
      )
    catch {
      @posoco-ext-mbtx.RuntimeError::ProtocolFailure(reason) =>
        assert_true(reason.contains("call budget"))
      error => raise error
    } noraise {
      _ => fail("child call budget was ignored")
    }
    let result = runtime.run(artifact, {}, invocation_id="output")
    assert_true(result.outcome is @protocol.Success(..))
  }) catch {
    @posoco-ext-mbtx.RuntimeError::BuildFailed(message) => fail(message)
    error => raise error
  }
}
