///|
fn guest_policy() -> Json {
  {
    "env": { "from_host": [] },
    "fs": { "read": [], "write": [] },
    "net": { "dns": [], "connect": [], "bind": [] },
    "process": { "allow": [] },
  }
}

///|
async fn communicate(
  process : &GuestProcess,
  input : Json,
  tools : Array[String],
  on_call : (async (String, Json) -> Outcome)?,
  frame_limit : Int32,
  max_pending : Int32,
  max_calls : Int32,
  output_limit : Int32,
  handshake_ms : Int32,
) -> InvocationResult {
  let session = @protocol.HostSession(max_pending~, max_calls~)
  defer session.close()
  let writer = @async.Mutex()
  let ready : @aqueue.Queue[Bool] = @aqueue.Queue(kind=Blocking(1))
  let mut greeted = false
  let logs = []
  let calls : Array[ToolCallTrace] = []
  let stderr_bytes = []
  let mut total = 0
  let account = fn(bytes : Bytes) raise {
    if bytes.length() > output_limit - total {
      raise RuntimeError::ProtocolFailure("invocation output budget exceeded")
    }
    total += bytes.length()
  }
  let send = async fn(message : @protocol.Message) {
    let bytes = @protocol.encode_frame(
      message.to_json(),
      max_frame_bytes=frame_limit,
    )
    writer.acquire()
    defer writer.release()
    process.write(bytes)
  }
  @async.with_task_group(group => {
    @async.pause()
    let err = group.spawn(() => {
      for ;; {
        match process.stderr() {
          None => break
          Some(bytes) => {
            account(bytes)
            for byte in bytes {
              stderr_bytes.push(byte)
            }
          }
        }
      }
    })
    let out = group.spawn(() => {
      let decoder = @protocol.Decoder(max_frame_bytes=frame_limit)
      for ;; {
        let bytes = match process.stdout() {
          Some(bytes) => bytes
          None => break
        }
        account(bytes)
        for frame in decoder.feed(bytes) {
          match session.receive(@protocol.Message::from_json(frame)) {
            Ready => {
              greeted = true
              send(
                @protocol.Invoke(
                  input~,
                  tools~,
                  max_pending~,
                  max_frame_bytes=frame_limit,
                ),
              )
              ready.put(true)
            }
            Call(id~, name~, arguments~) =>
              group.spawn_bg(() => {
                let outcome = if !tools.contains(name) {
                  @protocol.Failure(
                    code="CapabilityDenied",
                    content="tool is outside effective capability: " + name,
                    structured=None,
                  )
                } else {
                  match on_call {
                    None =>
                      @protocol.Failure(
                        code="ToolInvocationUnavailable",
                        content="Posoco scoped tool invocation is not connected",
                        structured=None,
                      )
                    Some(handle) => handle(name, arguments)
                  }
                }
                calls.push({ request_id: id, name, arguments, outcome, })
                send(session.reply(id, outcome))
              })
            Diagnostic(level~, content~) =>
              logs.push(Diagnostic::{ level, content, })
            Closing => ()
          }
        }
      }
      decoder.finish()
      if !greeted {
        ready.put(false)
      }
    })
    @async.with_timeout(handshake_ms, () => {
      if !ready.get() {
        ignore(process.wait())
      }
    }) catch {
      error =>
        if error is @async.TimeoutError {
          raise RuntimeError::TimedOut("handshake")
        } else {
          raise error
        }
    }
    let exit_code = process.wait()
    out.wait()
    err.wait()
    if exit_code != 0 {
      raise RuntimeError::GuestFailure(
        "guest exit status " +
        exit_code.to_string() +
        ": " +
        @utf8.decode(Bytes::from_array(stderr_bytes)),
      )
    }
    {
      outcome: session.finish(exit_code),
      stderr: @utf8.decode(Bytes::from_array(stderr_bytes)),
      logs,
      calls,
    }
  })
}

///|
priv enum Program {
  Source(String)
  File(String)
}

///|
/// A guest reaches the SDK, the wire protocol and JSON only through imports,
/// so an import-less script cannot greet on the protocol no matter how it is
/// compiled. The launcher would also give up in package resolution before the
/// compiler runs, which hides the real reason behind a toolchain error.
fn declares_imports(source : String) -> Bool {
  source.contains("import {")
}

///|
/// Standalone `.mbtx` compilation resolves the script as the synthetic
/// `moon/test/single` package. Core 0.10.18 exports both
/// `core/async/gzip` and `core/compress/gzip` under the `gzip` alias, and that
/// package imports both, so resolution fails before the compiler ever sees the
/// script. Anything else in a resolution failure stays the caller's problem
/// (a misspelled or unpublished import), so match the signature narrowly.
fn core_alias_collision(diagnostics : String) -> Bool {
  diagnostics.contains("Conflicting import alias") &&
  diagnostics.contains("moonbitlang/core/compress/gzip")
}

///|
fn core_alias_collision_message(diagnostics : String) -> String {
  "the MoonBit toolchain failed to resolve the script's package graph, so the compiler never ran and there are no diagnostics for the script itself. Core exports both `moonbitlang/core/async/gzip` and `moonbitlang/core/compress/gzip` under the same alias while standalone-file compilation imports both: this is a toolchain defect, not a defect in the submitted script, and resubmitting the same source fails identically. Update or pin the toolchain instead.\nThe launcher reported:\n" +
  diagnostics
}

///|
/// The launcher reports a resolution failure either as build diagnostics
/// (moon) or as guest stderr (moonx); both carry the same text.
fn core_alias_collision_error(error : Error) -> String? {
  let diagnostics = match error {
    RuntimeError::BuildFailed(diagnostics) => diagnostics
    RuntimeError::GuestFailure(message) => message
    _ => return None
  }
  if core_alias_collision(diagnostics) {
    Some(core_alias_collision_message(diagnostics))
  } else {
    None
  }
}

///|
async fn Runtime::execute(
  self : Runtime,
  program : Program,
  input : Json,
  invocation_id~ : String,
  tools~ : Array[String] = [],
  on_call? : async (String, Json) -> Outcome,
  timeout_ms~ : Int32 = 120000,
  handshake_ms~ : Int32 = 5000,
  max_frame_bytes~ : Int32 = 65536,
  max_pending~ : Int32 = 8,
  max_calls~ : Int32 = 128,
  max_output_bytes~ : Int32 = 1048576,
) -> InvocationResult {
  if self.closed {
    raise RuntimeError::Closed
  }
  if invocation_id == "" || self.active.contains(invocation_id) {
    raise RuntimeError::Invalid(
      "invocation id must be nonempty and unique while active",
    )
  }
  if timeout_ms <= 0 ||
    handshake_ms <= 0 ||
    max_frame_bytes <= 0 ||
    max_frame_bytes > 65536 ||
    max_pending <= 0 ||
    max_calls <= 0 ||
    max_output_bytes <= 0 ||
    tools.contains("*") {
    raise RuntimeError::Invalid(
      "invalid resource limits or wildcard tool capability",
    )
  }
  match program {
    Source(source) if source == "" || @utf8.encode(source).length() > 1048576 =>
      raise RuntimeError::Invalid("source must be 1..1048576 bytes")
    Source(source) if !declares_imports(source) =>
      raise RuntimeError::Invalid(
        "an mbtx script must open with an `import { ... }` block: the guest reaches the SDK, the wire protocol and JSON only through imports, and an import-less source cannot compile",
      )
    File(path) if path == "" || path.has_prefix("-") =>
      raise RuntimeError::Invalid(
        "program must be a nonempty file or package path",
      )
    _ => ()
  }
  let tools = tools.copy()
  let cancel_task : Ref[(() -> Unit)?] = Ref(None)
  let cancelled = Ref(false)
  self.active[invocation_id] = () => {
    cancelled.val = true
    if cancel_task.val is Some(cancel) {
      cancel()
    }
  }
  defer self.active.remove(invocation_id)
  @async.with_task_group(group => {
    @async.pause()
    let task = group.spawn(allow_failure=true, () => {
      match
        @async.handle_cancellation(() => {
          let toolchain = self.resolve_toolchain()
          @async.with_timeout(timeout_ms, () => {
            let directory = @async.protect_from_cancel(() => {
              temporary_directory("posoco-mbtx-invocation-")
            })
            defer remove_directory(directory)
            let policy = directory + "/policy.json"
            write_text(policy, guest_policy().stringify())
            let launcher = if self.build_cache is Some(_) &&
              program is Source(_) &&
              executable_failure(toolchain.moon) is None &&
              executable_failure(toolchain.moonrun) is None {
              Moon
            } else {
              toolchain.launcher
            }
            let path = match program {
              Source(source) => {
                let path = directory + "/program.mbtx"
                write_text(path, source)
                path
              }
              File(path) => canonical_path(path)
            }
            let (command, args) = match launcher {
              Moon => {
                let artifact = match program {
                  Source(source) if self.build_cache is Some(_) =>
                    self.build_cached_source(source, directory, toolchain)
                  _ => self.build_program(path, directory, toolchain)
                }
                (toolchain.moonrun, [artifact, "--policy", policy])
              }
              Moonx => {
                if !path.has_suffix(".mbtx") {
                  raise RuntimeError::Invalid(
                    "moonx requires a .mbtx file; use the Moon launcher for a local package or Wasm artifact",
                  )
                }
                (
                  toolchain.moonx,
                  ["--target", "wasm", "--experimental-policy", policy, path],
                )
              }
              Auto => abort("unresolved launcher")
            }
            with_process(
              command,
              args,
              None,
              true,
              process => {
                communicate(
                  process, input, tools, on_call, max_frame_bytes, max_pending, max_calls,
                  max_output_bytes, handshake_ms,
                )
              },
              extra_env=mbtx_env(toolchain),
            )
          }) catch {
            error =>
              if error is @async.TimeoutError {
                raise RuntimeError::TimedOut("invocation")
              } else {
                match core_alias_collision_error(error) {
                  Some(message) =>
                    raise RuntimeError::ToolchainUnavailable(message)
                  None => raise error
                }
              }
          }
        }) {
        Some(result) => result
        None => raise RuntimeError::Cancelled
      }
    })
    cancel_task.val = Some(() => task.cancel())
    if cancelled.val {
      task.cancel()
    }
    task.wait()
  }) catch {
    @protocol.ProtocolError::Invalid(reason) =>
      raise RuntimeError::ProtocolFailure(reason)
    error => raise error
  }
}
