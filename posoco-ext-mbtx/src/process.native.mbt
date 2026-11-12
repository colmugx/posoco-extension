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
    let (child_stdin, stdin) = @process.write_to_process()
    defer stdin.close()
    let (stdout, child_stdout) = @process.read_from_process()
    defer stdout.close()
    let (stderr, child_stderr) = @process.read_from_process()
    defer stderr.close()
    let process = @process.spawn(
      group,
      command,
      args,
      stdin=@process.ProcessInput::Shared(child_stdin),
      stdout=@process.ProcessOutput::Shared(child_stdout),
      stderr=@process.ProcessOutput::Shared(child_stderr),
      cwd?=cwd.map(path => path[:]),
      inherit_env~,
      extra_env~,
      no_wait=true,
      cancel_handler=@process.graceful_cancel(timeout=1000),
    )
    outcome.val = Some(body(NativeProcess::{ stdin, stdout, stderr, process, }))
  })
  match outcome.val {
    Some(result) => result
    None => abort("native process group completed without a result")
  }
}
