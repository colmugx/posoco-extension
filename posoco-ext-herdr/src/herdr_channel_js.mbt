///|
// js backend: one node:child_process spawn per `run`, both streams piped, exit and
// drains awaited as a single JSON envelope. The extern only loads node modules when
// invoked — the moon js test runner is Node, so js-target tests must stay on fakes.

///|
#external
priv type NodeSpawnOptions

///|
#external
priv type NodeProc

///|
#module("node:child_process")
extern "js" fn cp_spawn(
  file : String,
  args : FixedArray[String],
  options : NodeSpawnOptions,
) -> NodeProc = "spawn"

///|
extern "js" fn herdr_js_spawn_envelope(
  spawn : (String, FixedArray[String], NodeSpawnOptions) -> NodeProc,
  cmd : FixedArray[String],
) -> @js_async.Promise[String] =
  #| async (spawn, cmd) => {
  #|   const proc = spawn(cmd[0], cmd.slice(1), { stdio: ["ignore", "pipe", "pipe"] })
  #|   const drain = (stream) => stream
  #|     ? new Promise((resolve) => {
  #|         let text = ""
  #|         const finish = () => resolve(text)
  #|         stream.setEncoding("utf8")
  #|         stream.on("data", (chunk) => { text += chunk })
  #|         stream.on("end", finish)
  #|         stream.on("close", finish)
  #|         stream.on("error", finish)
  #|       })
  #|     : Promise.resolve("")
  #|   const [exitCode, stdout, stderr] = await Promise.all([
  #|     new Promise((resolve) => {
  #|       proc.on("close", (code) => resolve(code ?? -1))
  #|       proc.on("error", () => resolve(-1))
  #|     }),
  #|     drain(proc.stdout),
  #|     drain(proc.stderr),
  #|   ])
  #|   return JSON.stringify({ ok: true, exitCode, stdout, stderr })
  #| }

///|
priv struct JsSpawnResult {
  exit_code : Int
  stdout : String
  stderr : String
}

///|
async fn herdr_js_spawn_result(cmd : Array[String]) -> JsSpawnResult noraise {
  let json : Json = @json.parse(
    herdr_js_spawn_envelope(cp_spawn, FixedArray::from_array(cmd)).wait(),
  ) catch {
    _ =>
      return {
        exit_code: 2,
        stdout: "",
        stderr: "spawn envelope decode failed",
      }
  }
  let fields = match json {
    Object(fields) => fields
    _ =>
      return {
        exit_code: 2,
        stdout: "",
        stderr: "spawn envelope is not an object",
      }
  }
  let exit_code = match fields.get("exitCode") {
    Some(Number(value, ..)) => value.to_int()
    _ => 2
  }
  let stdout = match fields.get("stdout") {
    Some(String(text)) => text
    _ => ""
  }
  let stderr = match fields.get("stderr") {
    Some(String(text)) => text
    _ => ""
  }
  { exit_code, stdout, stderr, }
}

///|
priv struct JsHerdrCli {}

///|
impl HerdrCli for JsHerdrCli with fn run(
  _self : JsHerdrCli,
  argv : Array[String],
) -> (Int, String, String) raise @posoco.RuntimeError {
  let result = herdr_js_spawn_result(argv)
  (result.exit_code, result.stdout, result.stderr)
}
