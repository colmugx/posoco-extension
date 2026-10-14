///|
priv struct Bridge {
  registry : @fuwaroid.Fuwaroid[RegistryCmd, RegistryQuery, RegistryReply]
  writer : @async.Mutex
  slots : @async.Semaphore
  max_frame_bytes : Int32
}

///|
async fn Bridge::send(self : Bridge, message : @protocol.Message) -> Unit {
  let bytes = @protocol.encode_frame(
    message.to_json(),
    max_frame_bytes=self.max_frame_bytes,
  )
  self.writer.acquire()
  defer self.writer.release()
  @system_stdio.stdout.write(bytes)
}

///|
async fn Bridge::query(self : Bridge, query : RegistryQuery) -> RegistryReply {
  match self.registry.ask(query, timeout_ms=registry_timeout_ms) {
    Ok(Refused(reason)) => raise Failure::Failure(reason)
    Ok(reply) => reply
    Err(failure) =>
      raise Failure::Failure(
        registry_ask_failure("request registry query failed", failure),
      )
  }
}

///|
impl @sdk.ToolClient for Bridge with fn call(self, name, arguments) {
  self.slots.acquire()
  defer self.slots.release()
  // The shield keeps registration and cleanup adjacent: once the registry
  // admitted a request, the release below is always installed, so no
  // cancellation between the two can orphan a registration.
  let admitted = @async.protect_from_cancel(() => self.query(Acquire))
  match admitted {
    Admitted(id, waiter) => {
      defer (match self.registry.tell(Release(id~)) {
        Ok(_) => ()
        // Scope cancellation may stop the registry before its callers.
        Err(MailboxClosed) => ()
        Err(MailboxFull) =>
          raise Failure::Failure("request registry rejected request cleanup")
      })
      self.send(@protocol.Request(id~, name~, arguments~))
      waiter.get()
    }
    _ => raise Failure::Failure("unexpected request registry admission reply")
  }
}

///|
impl @sdk.LogSink for Bridge with fn log(self, level, content) {
  self.send(@protocol.Log(level~, content~))
}

///|
async fn Bridge::settle(
  self : Bridge,
  id : Int32,
  outcome : @protocol.Outcome,
) -> Unit {
  match self.query(Settle(id~, outcome~)) {
    Acked => ()
    _ => raise Failure::Failure("unexpected request registry settlement reply")
  }
}

///|
async fn receive_invocation() -> @protocol.Message {
  let decoder = @protocol.Decoder()
  for ;; {
    let chunk = match @system_stdio.stdin.read_some(max_len=8192) {
      Some(chunk) => chunk
      None => raise Failure::Failure("EOF before invocation")
    }
    let frames = decoder.feed(chunk)
    if frames.length() > 1 {
      raise Failure::Failure("unexpected messages before invocation")
    }
    if frames.length() == 1 {
      decoder.finish()
      return @protocol.Message::from_json(frames[0])
    }
  }
}

///|
async fn Bridge::receive_replies(self : Bridge) -> Unit {
  let decoder = @protocol.Decoder(max_frame_bytes=self.max_frame_bytes)
  for ;; {
    let chunk = match @system_stdio.stdin.read_some(max_len=8192) {
      Some(chunk) => chunk
      None => {
        decoder.finish()
        raise Failure::Failure("host closed invocation transport")
      }
    }
    for frame in decoder.feed(chunk) {
      match @protocol.Message::from_json(frame) {
        Reply(id~, outcome~) => self.settle(id, outcome)
        Cancel(reason~) =>
          raise Failure::Failure("host cancelled invocation: " + reason)
        _ => raise Failure::Failure("invalid host message during invocation")
      }
    }
  }
}

///|
/// One invocation per process. The handler and reply reader share a structured scope.
pub async fn serve(
  handler : async (@sdk.Context, Json) -> @protocol.Outcome,
) -> Unit {
  @system_stdio.stdout.write(
    @protocol.encode_frame(
      @protocol.Hello(protocol=@protocol.version).to_json(),
    ),
  )
  let (input, tools, max_pending, max_frame_bytes) = match
    receive_invocation() {
    Invoke(input~, tools~, max_pending~, max_frame_bytes~) =>
      (input, tools, max_pending, max_frame_bytes)
    _ => raise Failure::Failure("expected invocation after hello")
  }
  @async.with_task_group(group => {
    // Request registration, id allocation, reply settlement and the closed
    // state all fold through one private single-writer loop, so no request
    // map is shared between the reader and the callers. The loop never
    // awaits: I/O and waiter waits stay on the group's own tasks.
    let registry = @fuwaroid.Fuwaroid::spawn(
      group~,
      init=Registry::{ pending: Map([]), next_id: 1, closed: false, },
      on_cmd=registry_on_cmd,
      on_query=registry_on_query,
    )
    let bridge = Bridge::{
      registry,
      writer: @async.Mutex(),
      slots: @async.Semaphore(max_pending),
      max_frame_bytes,
    }
    let ctx = @sdk.Context(tools=bridge, allowed=tools, logs=bridge)
    defer ctx.close()
    group.spawn_bg(no_wait=true, () => bridge.receive_replies())
    let outcome = handler(ctx, input)
    match bridge.query(Finish) {
      Acked => ()
      _ => raise Failure::Failure("unexpected request registry finish reply")
    }
    ctx.close()
    bridge.send(@protocol.Result(outcome~))
  })
}
