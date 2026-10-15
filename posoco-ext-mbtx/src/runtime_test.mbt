///|
fn test_runtime() -> @posoco-ext-mbtx.Runtime {
  @posoco-ext-mbtx.Runtime(launcher=Moon)
}

///|
/// The unpublished SDK is a normal workspace dependency, not copied sources.
async fn[X] test_program(
  group : @async.TaskGroup[X],
  source : String,
  compile~ : Bool = true,
) -> String {
  let directory = fixture_directory()
  group.add_defer(() => fixture_remove(directory))
  let sdk = fixture_realpath(".")
  fixture_mkdir(directory + "/guest")
  fixture_write(
    directory + "/moon.work",
    "members = [\"./guest\", " + Json::string(sdk).stringify() + "]\n",
  )
  fixture_write(
    directory + "/guest/moon.mod",
    "name = \"mbtx/test-guest\"\nversion = \"0.0.0\"\nimport { \"colmugx/posoco-ext-mbtx@0.1.0\", \"moonbitlang/async@0.22.4\" }\n",
  )
  fixture_write(
    directory + "/guest/moon.pkg",
    "import { \"colmugx/posoco-ext-mbtx/sdk/stdio\" @mbtx, \"colmugx/posoco-ext-mbtx/sdk\", \"colmugx/posoco-ext-mbtx/protocol\", \"moonbitlang/async\" }\noptions(\"is-main\": true)\nsupported_targets = \"wasm\"\n",
  )
  fixture_write(
    directory + "/guest/main.mbt",
    source + "\n///|\nasync fn main { @mbtx.serve(run) }\n",
  )
  if !compile {
    return directory + "/guest"
  }
  let output = @async.with_timeout(30000, () => {
    fixture_compile(directory + "/guest")
  })
  for line in output.split("\n") {
    let json = @json.parse(line.to_owned()) catch { _ => continue }
    if json is { "artifacts_path": [String(path), ..], .. } {
      return path
    }
  }
  fail("compiler returned no artifact: " + output)
}

///|
let compute_source : String =
  #|async fn run(ctx : @sdk.Context, input : Json) -> @sdk.Outcome {
  #|  ctx.log("info", "computing")
  #|  @protocol.Success(content="done", structured=Some({"answer": 42, "input": input}))
  #|}

///|
async test "normal SDK package executes repeatedly without provisioning dependency roots" {
  let runtime = test_runtime()
  @async.with_task_group(group => {
    group.add_defer(() => @async.protect_from_cancel(() => runtime.close()))
    let program = test_program(group, compute_source, compile=false)
    for id in ["compute", "repeat"] {
      let result = runtime.run_file(
        program,
        { "name": "MoonBit" },
        invocation_id=id,
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
    }
  }) catch {
    @posoco-ext-mbtx.RuntimeError::BuildFailed(message) => fail(message)
    error => raise error
  }
}
