///|
async test "compiler diagnostics are surfaced and a failed source does not disable retry" {
  let runtime = test_runtime()
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    try runtime.run(invalid_script_source, {}, invocation_id="compile") catch {
      @posoco-ext-mbtx.RuntimeError::BuildFailed(diagnostics) =>
        assert_true(diagnostics.contains("unknown_value"))
      error => raise error
    } noraise {
      _ => fail("invalid source compiled successfully")
    }
    let good = test_program(group, compute_source)
    let result = runtime.run_file(good, {}, invocation_id="compile")
    assert_true(result.outcome is @protocol.Success(..))
    runtime.close()
    try runtime.run_file(good, {}, invocation_id="closed") catch {
      @posoco-ext-mbtx.RuntimeError::Closed => ()
      error => raise error
    } noraise {
      _ => fail("closed runtime accepted an invocation")
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
    let noisy = test_program(group, noisy_source)
    try runtime.run_file(noisy, {}, invocation_id="noisy") catch {
      @posoco-ext-mbtx.RuntimeError::ProtocolFailure(reason) =>
        assert_true(reason.contains("JSON"))
      error => raise error
    } noraise {
      _ => fail("unframed stdout was accepted")
    }
    let crashing = test_program(
      group, "async fn run(_ctx : @sdk.Context, _input : Json) -> @sdk.Outcome { raise Failure::Failure(\"guest failed\") }",
    )
    try runtime.run_file(crashing, {}, invocation_id="crash") catch {
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
    let artifact = test_program(group, compute_source)
    try
      runtime.run_file(artifact, {}, invocation_id="output", max_output_bytes=8)
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
    let workflow = test_program(group, source)
    try
      runtime.run_file(
        workflow,
        {},
        invocation_id="calls",
        tools=["read"],
        on_call=(name, args) => EchoInvoker::{ calls: [], }.invoke(name, args),
        max_calls=1,
      )
    catch {
      @posoco-ext-mbtx.RuntimeError::ProtocolFailure(reason) =>
        assert_true(reason.contains("call budget"))
      error => raise error
    } noraise {
      _ => fail("child call budget was ignored")
    }
    let result = runtime.run_file(artifact, {}, invocation_id="output")
    assert_true(result.outcome is @protocol.Success(..))
  }) catch {
    @posoco-ext-mbtx.RuntimeError::BuildFailed(message) => fail(message)
    error => raise error
  }
}

///|
/// A guest that abandons an in-flight request must not hang the invocation,
/// must not receive a fabricated call outcome, and must release the request
/// registration it leaves behind. Whether the request frame already reached
/// the host is a scheduling race: once it did, the host protocol rejects the
/// final result as pending; if it did not, the invocation is legitimately
/// clean. Both exits must be prompt and explicit.
async test "an abandoned in-flight request exits promptly without a fabricated outcome" {
  let runtime = test_runtime()
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    let source =
      #|async fn run(ctx : @sdk.Context, _input : Json) -> @sdk.Outcome {
      #|  @async.with_task_group(inner => {
      #|    inner.spawn_bg(no_wait=true, () => ignore(ctx.call("read", {})))
      #|    @async.sleep(50)
      #|    @protocol.Success(content="abandoned", structured=None)
      #|  })
      #|}
    let artifact = test_program(group, source)
    let abandoned_started = @async.now()
    try
      runtime.run_file(
        artifact,
        {},
        invocation_id="abandoned",
        tools=["read"],
        on_call=(name, args) => {
          BlockingInvoker::{
            entered: @aqueue.Queue(kind=Blocking(1)),
            settled: false,
          }.invoke(name, args)
        },
      )
    catch {
      @posoco-ext-mbtx.RuntimeError::ProtocolFailure(reason) => {
        assert_true(reason.contains("pending"))
        assert_true(@async.now() - abandoned_started < 30000L)
      }
      error => raise error
    } noraise {
      result => {
        assert_true(
          result.outcome is @protocol.Success(content="abandoned", ..),
        )
        assert_true(@async.now() - abandoned_started < 30000L)
      }
    }
    let recovery = test_program(group, compute_source)
    let result = runtime.run_file(recovery, {}, invocation_id="after-abandon")
    assert_true(result.outcome is @protocol.Success(..))
  }) catch {
    @posoco-ext-mbtx.RuntimeError::BuildFailed(message) => fail(message)
    error => raise error
  }
}
