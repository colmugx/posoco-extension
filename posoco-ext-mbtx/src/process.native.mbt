///|
priv struct NativeProcess {
  stdin : @process.WriteToProcess
  stdout : @process.ReadFromProcess
  stderr : @process.ReadFromProcess
  process : @process.Process
}

///|
impl GuestProcess for NativeProcess with fn write(self, bytes) {
  self.stdin.write(bytes[:])
}

///|
impl GuestProcess for NativeProcess with fn stdout(self) {
  self.stdout.read()
}

///|
impl GuestProcess for NativeProcess with fn stderr(self) {
  self.stderr.read()
}

///|
impl GuestProcess for NativeProcess with fn wait(self) {
  self.process.wait()
}

///|
async fn[X] with_process(
  command : String,
  args : Array[String],
  cwd : String?,
  inherit_env : Bool,
  body : async (&GuestProcess) -> X,
  extra_env~ : Map[String, String] = Map([]),
) -> X {
  let outcome : Ref[X?] = Ref(None)
  @async.with_task_group(group => {
    @async.pause()
    // Use process-owned pipes. A Shared(stdout/stderr) endpoint must be
    // explicitly closed by its caller immediately after spawning. Keeping
    // that write end open prevents readers from ever receiving EOF, so both
    // collect_process and communicate can deadlock after the child exits.
    //
    // Collect/FeedFromParent let Process own the child ends instead, with
    // only the parent-facing handles exposed on the returned process.
    let process = @process.spawn(
      group,
      command,
      args,
      stdin=@process.ProcessInput::FeedFromParent,
      stdout=@process.ProcessOutput::Collect,
      stderr=@process.ProcessOutput::Collect,
      cwd?=cwd.map(path => path[:]),
      inherit_env~,
      extra_env~,
      no_wait=true,
      cancel_handler=@process.graceful_cancel(timeout=1000),
    )
    defer process.stdin.close()
    defer process.stdout.close()
    defer process.stderr.close()
    outcome.val = Some(
      body(
        NativeProcess::{
          stdin: process.stdin,
          stdout: process.stdout,
          stderr: process.stderr,
          process,
        },
      ),
    )
  })
  match outcome.val {
    Some(result) => result
    None => abort("native process group completed without a result")
  }
}
