///|
// js (bun) backend: one Bun.spawn per `run`, both streams piped, exit and
// drains awaited as a single JSON envelope (astgrep pattern). The extern
// only touches Bun when invoked — the moon js test runner is Node, so
// js-target tests must stay on fakes.

///|
extern "js" fn herdr_js_spawn_envelope(
  cmd : FixedArray[String],
) -> @js_async.Promise[String] =
  #| async (cmd) => {
  #|   const proc = Bun.spawn(cmd, { stdout: "pipe", stderr: "pipe" });
  #|   const [exitCode, stdout, stderr] = await Promise.all([
  #|     proc.exited,
  #|     new Response(proc.stdout).text(),
  #|     new Response(proc.stderr).text(),
  #|   ]);
  #|   return JSON.stringify({ ok: true, exitCode, stdout, stderr });
  #| }

///|
priv struct JsSpawnResult {
  exit_code : Int
  stdout : String
  stderr : String
}

///|
/// Await the spawn envelope. `noraise`: a rejected promise (e.g. missing
/// binary) or a bad payload degrades to a nonzero exit, never a raise.
async fn herdr_js_spawn_result(cmd : Array[String]) -> JsSpawnResult noraise {
  let json : Json = @json.parse(
    herdr_js_spawn_envelope(FixedArray::from_array(cmd)).wait(),
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
