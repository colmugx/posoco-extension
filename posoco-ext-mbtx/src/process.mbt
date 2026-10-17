///|
priv trait GuestProcess {
  async fn write(Self, Bytes) -> Unit
  async fn stdout(Self) -> Bytes?
  async fn stderr(Self) -> Bytes?
  async fn wait(Self) -> Int32
}

///|
async fn collect_process(
  command : String,
  args : Array[String],
  cwd : String?,
  max_bytes~ : Int32 = 1048576,
  extra_env~ : Map[String, String] = Map([]),
) -> (Int32, String) {
  with_process(command, args, cwd, true, process => {
    @async.with_task_group(group => {
      @async.pause()
      let output = []
      let diagnostics = []
      let mut total = 0
      let drain = async fn(read : async () -> Bytes?, target : Array[Byte]) {
        for ;; {
          match read() {
            None => break
            Some(bytes) => {
              total += bytes.length()
              if total > max_bytes {
                raise Failure::Failure("process output budget exceeded")
              }
              for byte in bytes {
                target.push(byte)
              }
            }
          }
        }
      }
      let out = group.spawn(() => drain(() => process.stdout(), output))
      let err = group.spawn(() => drain(() => process.stderr(), diagnostics))
      let code = process.wait()
      out.wait()
      err.wait()
      (
        code,
        @utf8.decode(Bytes::from_array(output)) +
        @utf8.decode(Bytes::from_array(diagnostics)),
      )
    })
  }, extra_env~)
}
