///|
/// Wire fixture independent of the unpublished SDK, exercising real script imports.
let script_source : String =
  #|import {
  #|  "moonbitlang/async@0.22.5",
  #|  "moonbitlang/async@0.22.5/stdio",
  #|  "moonbitlang/core/json",
  #|}
  #|async fn main {
  #|  @stdio.stdout.write("{\"type\":\"hello\",\"protocol\":1}\n")
  #|  guard @stdio.stdin.read_until("\n") is Some(line) else { fail("missing invocation") }
  #|  guard @json.parse(line) is { "input": input, .. } else { fail("missing input") }
  #|  if input is { "block": true, .. } {
  #|    @stdio.stdout.write("{\"type\":\"request\",\"id\":1,\"name\":\"read\",\"arguments\":{}}\n")
  #|    @async.sleep(60000)
  #|  }
  #|  let result : Json = { "type": "result", "outcome": { "kind": "success", "content": "script", "structured": input } }
  #|  @stdio.stdout.write(result.stringify() + "\n")
  #|}

///|
async test "installed moon and moonx execute normal mbtx scripts with normal imports" {
  for
    launcher in [
      @posoco-ext-mbtx.Launcher::Moon,
      @posoco-ext-mbtx.Launcher::Moonx,
    ] {
    let runtime = @posoco-ext-mbtx.Runtime(launcher~)
    @async.with_task_group(group => {
      group.add_defer(() => runtime.close())
      let result = runtime.run(
        script_source,
        { "value": 42 },
        invocation_id="script",
      )
      assert_eq(
        result.outcome,
        @protocol.Success(content="script", structured=Some({ "value": 42 })),
      )
    })
  }
}

///|
async test "moonx alone is sufficient and missing launchers have an explicit error" {
  let runtime = @posoco-ext-mbtx.Runtime(
    moon="mbtx-no-such-moon",
    moonrun="mbtx-no-such-moonrun",
  )
  let result = runtime.run(script_source, {}, invocation_id="moonx-only")
  assert_true(result.outcome is @protocol.Success(content="script", ..))
  runtime.close()
  let missing = @posoco-ext-mbtx.Runtime(
    moon="mbtx-no-such-moon",
    moonx="mbtx-no-such-moonx",
  )
  try missing.run(script_source, {}, invocation_id="missing") catch {
    @posoco-ext-mbtx.RuntimeError::ToolchainUnavailable(message) =>
      assert_true(message.contains("moonx"))
    error => raise error
  } noraise {
    _ => fail("missing toolchain was accepted")
  }
  missing.close()
}

///|
async test "moonx compiler failure before hello reports diagnostics rather than handshake timeout" {
  let runtime = @posoco-ext-mbtx.Runtime(launcher=Moonx)
  @async.with_task_group(group => {
    group.add_defer(() => runtime.close())
    try
      runtime.run(
        "fn main { unknown_value }",
        {},
        invocation_id="bad",
        handshake_ms=30000,
      )
    catch {
      @posoco-ext-mbtx.RuntimeError::GuestFailure(message) =>
        assert_true(message.contains("unknown_value"))
      error => raise error
    } noraise {
      _ => fail("invalid script succeeded")
    }
    let result = runtime.run(script_source, {}, invocation_id="bad")
    assert_true(result.outcome is @protocol.Success(..))
  })
}

///|
async test "moonx cancellation settles child calls and permits retry" {
  let runtime = @posoco-ext-mbtx.Runtime(launcher=Moonx)
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    let invoker = BlockingInvoker::{
      entered: @aqueue.Queue(kind=Blocking(1)),
      settled: false,
    }
    let call = group.spawn(allow_failure=true, () => {
      runtime.run(
        script_source,
        { "block": true },
        invocation_id="cancel",
        tools=["read"],
        invoker~,
      )
    })
    @async.with_timeout(30000, () => invoker.entered.get())
    let started = @async.now()
    assert_true(runtime.cancel("cancel"))
    try call.wait() catch {
      @posoco-ext-mbtx.RuntimeError::Cancelled => ()
      error => raise error
    } noraise {
      _ => fail("cancelled script succeeded")
    }
    assert_true(@async.now() - started < 3000L)
    assert_true(invoker.settled)
    let result = runtime.run(script_source, {}, invocation_id="cancel")
    assert_true(result.outcome is @protocol.Success(..))
  })
}
