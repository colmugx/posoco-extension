///|
/// Whitebox tests for AcpTerminal: streaming order, timeout and
/// cancellation cleanup, error mapping, and the wire shapes that reach the
/// fake host.

// ---------------------------------------------------------------- fixtures

///|
/// Recording stand-in for the host side of the terminal service. Output
/// polls replay cumulative snapshots in order (the last one repeats);
/// `exitStatus` appears once `exit_after_polls` polls have happened.
priv struct FakeTerminalHost {
  snapshots : Array[String]
  exit_after_polls : Int
  exit_code : UInt64
  signal_exit : Bool
  fail_create : @acp.AgentContextError?
  fail_output_from_poll : Int
  create_params : Array[@acp.TerminalCreateParams]
  mut output_polls : Int
  mut kills : Int
  mut releases : Int
  mut waits : Int
}

///|
fn FakeTerminalHost::FakeTerminalHost(
  snapshots? : Array[String] = [""],
  exit_after_polls? : Int = 1,
  exit_code? : UInt64 = 0UL,
  signal_exit? : Bool = false,
  fail_create? : @acp.AgentContextError? = None,
  fail_output_from_poll? : Int = 0,
) -> FakeTerminalHost {
  {
    snapshots,
    exit_after_polls,
    exit_code,
    signal_exit,
    fail_create,
    fail_output_from_poll,
    create_params: [],
    output_polls: 0,
    kills: 0,
    releases: 0,
    waits: 0,
  }
}

///|
/// Build a real acp.mbt `AgentContext` over the recording terminal broker.
fn fake_terminal_context(host : FakeTerminalHost) -> @acp.AgentContext {
  @acp.agent_context(
    request_broker=request => {
      match request {
        TerminalCreate(params) => {
          host.create_params.push(params)
          match host.fail_create {
            Some(error) => Err(error)
            None =>
              Ok(
                AgentReplyTerminalCreate({
                  terminal_id: "term-1",
                  meta: Omitted,
                }),
              )
          }
        }
        TerminalOutput(_) => {
          host.output_polls = host.output_polls + 1
          if host.fail_output_from_poll > 0 &&
            host.output_polls >= host.fail_output_from_poll {
            Err(AgentContextBrokerFailure(method_name="terminal/output"))
          } else {
            let index = if host.output_polls - 1 < host.snapshots.length() {
              host.output_polls - 1
            } else {
              host.snapshots.length() - 1
            }
            let exit : @acp.ProtocolNullable[@acp.TerminalExitStatus] = if host.output_polls >=
              host.exit_after_polls {
              Value({
                exit_code: if host.signal_exit {
                  Null
                } else {
                  Value(host.exit_code)
                },
                signal: if host.signal_exit {
                  Value("SIGKILL")
                } else {
                  Null
                },
                meta: Omitted,
              })
            } else {
              Omitted
            }
            let result : @acp.TerminalOutputResult = {
              output: host.snapshots[index],
              truncated: false,
              exit_status: exit,
              meta: Omitted,
            }
            Ok(AgentReplyTerminalOutput(result))
          }
        }
        TerminalWaitForExit(_) => {
          host.waits = host.waits + 1
          let result : @acp.TerminalWaitForExitResult = {
            exit_code: if host.signal_exit {
              Null
            } else {
              Value(host.exit_code)
            },
            signal: if host.signal_exit {
              Value("SIGKILL")
            } else {
              Null
            },
            meta: Omitted,
          }
          Ok(AgentReplyTerminalWaitForExit(result))
        }
        TerminalKill(_) => {
          host.kills = host.kills + 1
          Ok(AgentReplyTerminalKill({ meta: Omitted, }))
        }
        TerminalRelease(_) => {
          host.releases = host.releases + 1
          Ok(AgentReplyTerminalRelease({ meta: Omitted, }))
        }
        _ => Err(AgentContextBrokerFailure(method_name="unused-request"))
      }
    },
    notification_broker=_ => Ok(()),
  )
}

// ------------------------------------------------------------------ happy

///|
async test "terminal run streams chunks in order and returns exit code" {
  let host = FakeTerminalHost::FakeTerminalHost(
    snapshots=["Hel", "Hello, ", "Hello, world"],
    exit_after_polls=3,
    exit_code=7UL,
  )
  let terminal = AcpTerminal::AcpTerminal(
    context=fake_terminal_context(host),
    session_id="s1",
  )
  let chunks : Array[String] = []
  let emit = (chunk : String) => chunks.push(chunk)
  let result = terminal.run("echo", cwd="/tmp", on_output=emit)
  assert_eq(chunks.length(), 3)
  assert_eq(chunks[0], "Hel")
  assert_eq(chunks[1], "lo, ")
  assert_eq(chunks[2], "world")
  assert_eq(result.exit_code, Some(7))
  assert_eq(result.output, "Hello, world")
  assert_eq(host.waits, 1)
  assert_eq(host.kills, 0)
  assert_eq(host.releases, 1)
}

///|
async test "terminal run forwards command and cwd to create" {
  let host = FakeTerminalHost::FakeTerminalHost()
  let terminal = AcpTerminal::AcpTerminal(
    context=fake_terminal_context(host),
    session_id="s1",
  )
  ignore(terminal.run("make check", cwd="/repo"))
  assert_eq(host.create_params.length(), 1)
  let params = host.create_params[0]
  assert_eq(params.session_id, "s1")
  assert_eq(params.command, "make check")
  assert_eq(params.cwd, Value("/repo"))
  assert_true(params.args is Omitted)
}

///|
async test "terminal run without callback still accumulates output" {
  let host = FakeTerminalHost::FakeTerminalHost(
    snapshots=["one", "one two"],
    exit_after_polls=2,
  )
  let terminal = AcpTerminal::AcpTerminal(
    context=fake_terminal_context(host),
    session_id="s1",
  )
  let result = terminal.run("count", cwd="/tmp")
  assert_eq(result.output, "one two")
  assert_eq(result.exit_code, Some(0))
}

///|
async test "terminal signal exit yields absent exit code" {
  let host = FakeTerminalHost::FakeTerminalHost(
    snapshots=["killed"],
    exit_after_polls=1,
    signal_exit=true,
  )
  let terminal = AcpTerminal::AcpTerminal(
    context=fake_terminal_context(host),
    session_id="s1",
  )
  let result = terminal.run("serve", cwd="/tmp")
  assert_true(result.exit_code is None)
  assert_eq(result.output, "killed")
  assert_eq(host.waits, 1)
  assert_eq(host.kills, 0)
  assert_eq(host.releases, 1)
}

// ------------------------------------------------------- failure and cleanup

///|
async test "terminal run timeout kills and releases once with partial output" {
  let host = FakeTerminalHost::FakeTerminalHost(
    snapshots=["out-1:", "out-1:out-2"],
    exit_after_polls=1000,
  )
  let terminal = AcpTerminal::AcpTerminal(
    context=fake_terminal_context(host),
    session_id="s1",
  )
  let outcome : Result[AcpTerminalResult, AcpTerminalError] = Ok(
    terminal.run("sleep", cwd="/tmp", timeout_ms=60),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(TerminalTimedOut(timeout_ms~, partial_output~)) => {
      assert_eq(timeout_ms, 60)
      assert_eq(partial_output, "out-1:out-2")
    }
    _ => fail("expected timeout")
  }
  assert_eq(host.kills, 1)
  assert_eq(host.releases, 1)
  assert_eq(host.waits, 0)
}

///|
async test "terminal run maps host output failure with method name and cleans up" {
  let host = FakeTerminalHost::FakeTerminalHost(
    snapshots=["partial-line"],
    exit_after_polls=1000,
    fail_output_from_poll=2,
  )
  let terminal = AcpTerminal::AcpTerminal(
    context=fake_terminal_context(host),
    session_id="s1",
  )
  let outcome : Result[AcpTerminalResult, AcpTerminalError] = Ok(
    terminal.run("flaky", cwd="/tmp"),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(HostCallFailed(method_name~, cause~)) => {
      assert_eq(method_name, "terminal/output")
      match cause {
        AgentContextBrokerFailure(method_name~) =>
          assert_eq(method_name, "terminal/output")
        _ => fail("expected broker failure cause")
      }
    }
    _ => fail("expected host call failure")
  }
  assert_eq(host.kills, 1)
  assert_eq(host.releases, 1)
}

///|
async test "terminal create failure maps with method name and no cleanup" {
  let host = FakeTerminalHost::FakeTerminalHost(
    fail_create=Some(AgentContextUnavailable(method_name="terminal/create")),
  )
  let terminal = AcpTerminal::AcpTerminal(
    context=fake_terminal_context(host),
    session_id="s1",
  )
  let outcome : Result[AcpTerminalResult, AcpTerminalError] = Ok(
    terminal.run("boom", cwd="/tmp"),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(HostCallFailed(method_name~, cause~)) => {
      assert_eq(method_name, "terminal/create")
      match cause {
        AgentContextUnavailable(method_name~) =>
          assert_eq(method_name, "terminal/create")
        _ => fail("expected unavailable cause")
      }
    }
    _ => fail("expected host call failure")
  }
  assert_eq(host.output_polls, 0)
  assert_eq(host.kills, 0)
  assert_eq(host.releases, 0)
}

///|
async test "terminal run cancellation kills releases and keeps cancellation identity" {
  let host = FakeTerminalHost::FakeTerminalHost(
    snapshots=["pre-"],
    exit_after_polls=1000,
  )
  let terminal = AcpTerminal::AcpTerminal(
    context=fake_terminal_context(host),
    session_id="s1",
  )
  @async.with_task_group(group => {
    let recorded : Array[AcpTerminalError] = []
    let task = group.spawn(() => {
      let outcome : Result[AcpTerminalResult, AcpTerminalError] = Ok(
        terminal.run("tail -f log", cwd="/tmp"),
      ) catch {
        error => Err(error)
      }
      match outcome {
        Err(error) => recorded.push(error)
        Ok(_) => fail("expected the cancelled run to fail")
      }
    })
    @async.sleep(40)
    task.cancel()
    @async.sleep(20)
    assert_eq(recorded.length(), 1)
    match recorded[0] {
      TerminalCancelled(partial_output~) => assert_eq(partial_output, "pre-")
      _ => fail("expected TerminalCancelled")
    }
    assert_eq(host.kills, 1)
    assert_eq(host.releases, 1)
  })
}
