///|
fn test_runtime() -> @posoco-ext-mbtx.Runtime {
  @posoco-ext-mbtx.Runtime(
    sdk_source_root="src",
    async_source_root="../.mooncakes/moonbitlang/async",
    fuwaroid_source_root="../.mooncakes/colmugx/fuwaroid",
  )
}

///|
let compute_source : String =
  #|async fn run(ctx : @sdk.Context, input : Json) -> @sdk.Outcome {
  #|  ctx.log("info", "computing")
  #|  @protocol.Success(content="done", structured=Some({"answer": 42, "input": input}))
  #|}

///|
async test "runtime compiles an SDK guest and reuses its immutable artifact" {
  let runtime = test_runtime()
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    let artifact = runtime.build(compute_source)
    let cached = runtime.build(compute_source)
    assert_eq(artifact.identity(), cached.identity())
    let result = runtime.run(
      artifact,
      { "name": "MoonBit" },
      invocation_id="compute",
    )
    assert_eq(
      result.outcome,
      @protocol.Success(
        content="done",
        structured=Some({ "answer": 42, "input": { "name": "MoonBit" } }),
      ),
    )
    assert_eq(result.logs.length(), 1)
    assert_eq(result.logs[0].content, "computing")
    assert_eq(result.stderr, "")
  }) catch {
    @posoco-ext-mbtx.RuntimeError::BuildFailed(message) => fail(message)
    error => raise error
  }
}
