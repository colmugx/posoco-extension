///|
// Native backend: one herdr CLI child per `run`. Streams stay separate
// (`collect_output`, never the merged variant) because herdr's result JSON
// and error JSON ride different streams.

///|
priv struct NativeHerdrCli {}

///|
impl HerdrCli for NativeHerdrCli with fn run(
  _self : NativeHerdrCli,
  argv : Array[String],
) -> (Int, String, String) raise @posoco.RuntimeError {
  let (exit_code, out, err) = @process.collect_output(argv[0], argv) catch {
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        "herdr_delegate: failed to spawn '\{argv[0]}'",
      )
  }
  // Decode failure degrades to empty text: the CLI's payloads are plain
  // text/JSON and the exit code still carries the verdict.
  let stdout = out.text() catch { _ => "" }
  let stderr = err.text() catch { _ => "" }
  (exit_code, stdout, stderr)
}
