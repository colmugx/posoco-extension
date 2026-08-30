///|
/// Whitebox tests for `AcpHostFs`: params fidelity over the typed reverse
/// calls and the error mapping onto `AcpHostFsError`.

// ---------------------------------------------------------------- fixtures

///|
/// Recording stand-in for the ACP host (client) side of `fs/*` requests.
/// Reads return the scripted content; writes are only recorded; both can be
/// switched to fail.
priv struct FakeFsHost {
  reads : Array[@acp.ReadTextFileParams]
  writes : Array[@acp.WriteTextFileParams]
  content : String
  mut fail : @acp.AgentContextError?
}

///|
fn FakeFsHost::FakeFsHost(content? : String = "host file body") -> FakeFsHost {
  { reads: [], writes: [], content, fail: None, }
}

///|
/// Build a real acp.mbt `AgentContext` over the recording fs brokers.
fn fake_fs_context(host : FakeFsHost) -> @acp.AgentContext {
  @acp.agent_context(
    request_broker=request => {
      match request {
        FsReadTextFile(params) => {
          host.reads.push(params)
          match host.fail {
            Some(error) => Err(error)
            None =>
              Ok(
                AgentReplyFsReadTextFile({
                  content: host.content,
                  meta: Omitted,
                }),
              )
          }
        }
        FsWriteTextFile(params) => {
          host.writes.push(params)
          match host.fail {
            Some(error) => Err(error)
            None => Ok(AgentReplyFsWriteTextFile({ meta: Omitted, }))
          }
        }
        _ => Err(AgentContextBrokerFailure(method_name="unused-request"))
      }
    },
    notification_broker=_ => Ok(()),
  )
}

// ------------------------------------------------------------------- tests

///|
async test "read returns host content and sends path with session stamp" {
  let host = FakeFsHost::FakeFsHost(content="L1\nL2\nL3")
  let fs = AcpHostFs(context=fake_fs_context(host), session_id="s1")
  let text = fs.read_text_file(path="/tmp/notes.txt")
  assert_eq(text, "L1\nL2\nL3")
  assert_eq(host.reads.length(), 1)
  let params = host.reads[0]
  assert_eq(params.session_id, "s1")
  assert_eq(params.path, "/tmp/notes.txt")
  // Whole-file read: no line/limit window, no meta.
  assert_true(params.line is Omitted)
  assert_true(params.limit is Omitted)
  assert_true(params.meta is Omitted)
}

///|
async test "write delivers path and content to the host" {
  let host = FakeFsHost::FakeFsHost()
  let fs = AcpHostFs(context=fake_fs_context(host), session_id="s42")
  fs.write_text_file(path="/tmp/out.txt", content="hello host")
  assert_eq(host.reads.length(), 0)
  assert_eq(host.writes.length(), 1)
  let params = host.writes[0]
  assert_eq(params.session_id, "s42")
  assert_eq(params.path, "/tmp/out.txt")
  assert_eq(params.content, "hello host")
  assert_true(params.meta is Omitted)
}

///|
async test "host failure maps to AcpHostFsError with the method name" {
  let host = FakeFsHost::FakeFsHost()
  host.fail = Some(AgentContextBrokerFailure(method_name="fs/read_text_file"))
  let fs = AcpHostFs(context=fake_fs_context(host), session_id="s1")
  let read_outcome : Result[String, AcpHostFsError] = Ok(
    fs.read_text_file(path="/gone.txt"),
  ) catch {
    error => Err(error)
  }
  match read_outcome {
    Err(HostFsCallFailed(method_name~, cause~)) => {
      assert_eq(method_name, "read_text_file")
      assert_true(cause is AgentContextBrokerFailure(_))
    }
    _ => fail("expected HostFsCallFailed from read")
  }
  host.fail = Some(AgentContextCancelled(method_name="fs/write_text_file"))
  let write_outcome : Result[Unit, AcpHostFsError] = Ok(
    fs.write_text_file(path="/gone.txt", content="x"),
  ) catch {
    error => Err(error)
  }
  match write_outcome {
    Err(HostFsCallFailed(method_name~, cause~)) => {
      assert_eq(method_name, "write_text_file")
      assert_true(cause is AgentContextCancelled(_))
    }
    _ => fail("expected HostFsCallFailed from write")
  }
}
