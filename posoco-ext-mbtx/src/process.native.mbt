///|
priv struct NativeProcess {
  stdin : @process.WriteToProcess
  stdout : @process.ReadFromProcess
  stderr : @process.ReadFromProcess
  process : @process.Process
}

///|
impl GuestProcess for NativeProcess with fn write(self, bytes) {
  self.stdin.write(bytes)
}

///|
impl GuestProcess for NativeProcess with fn stdout(self) {
  self.stdout.read_some(max_len=8192)
}

///|
impl GuestProcess for NativeProcess with fn stderr(self) {
  self.stderr.read_some(max_len=8192)
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
) -> X {
  @async.with_task_group(group => {
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
      stdin=child_stdin,
      stdout=child_stdout,
      stderr=child_stderr,
      cwd?=cwd.map(path => path[:]),
      inherit_env~,
      no_wait=true,
      cancel_handler=@process.graceful_cancel(timeout=1000),
    )
    body(NativeProcess::{ stdin, stdout, stderr, process, })
  })
}
