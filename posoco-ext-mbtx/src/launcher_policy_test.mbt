///|
async test "auto falls back to moon and an early cancelled invocation can retry" {
  let runtime = @posoco-ext-mbtx.Runtime(moonx="mbtx-no-such-moonx")
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    let call = group.spawn(allow_failure=true, () => {
      runtime.run(script_source, {}, invocation_id="early")
    })
    @async.with_timeout(1000, () => {
      for ;; {
        if runtime.cancel("early") {
          break
        }
        @async.sleep(1)
      }
    })
    try call.wait() catch {
      @posoco-ext-mbtx.RuntimeError::Cancelled => ()
      error => raise error
    } noraise {
      _ => fail("cancelled startup succeeded")
    }
    let result = runtime.run(script_source, {}, invocation_id="early")
    assert_true(result.outcome is @protocol.Success(..))
  })
}

///|
async test "normal imports and embedded policy do not bypass host guest filesystem policy" {
  let source =
    #|// policy:
    #|//   fs:
    #|//     read: ["."]
    #|import {
    #|  "moonbitlang/async@0.22.5",
    #|  "moonbitlang/async@0.22.5/stdio",
    #|  "moonbitlang/async@0.22.5/fs",
    #|}
    #|async fn main {
    #|  @stdio.stdout.write("{\"type\":\"hello\",\"protocol\":1}\n")
    #|  ignore(@stdio.stdin.read_until("\n"))
    #|  ignore(@fs.read_file("moon.mod"))
    #|}
  for
    launcher in [
      @posoco-ext-mbtx.Launcher::Moon,
      @posoco-ext-mbtx.Launcher::Moonx,
    ] {
    let runtime = @posoco-ext-mbtx.Runtime(launcher~)
    @async.with_task_group(group => {
      group.add_defer(() => runtime.close())
      try runtime.run(source, {}, invocation_id="policy") catch {
        @posoco-ext-mbtx.RuntimeError::GuestFailure(message) =>
          assert_true(message.contains("denied"), msg=message)
        @posoco-ext-mbtx.RuntimeError::BuildFailed(message) => fail(message)
        error => raise error
      } noraise {
        _ => fail("guest filesystem access was accepted")
      }
    })
  }
}
