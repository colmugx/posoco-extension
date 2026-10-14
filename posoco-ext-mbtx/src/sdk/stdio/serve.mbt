///|
priv struct Bridge {
  writer : @async.Mutex
  slots : @async.Semaphore
  pending : Map[Int32, @aqueue.Queue[@protocol.Outcome]]
  max_frame_bytes : Int32
  mut next_id : Int32
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
impl @sdk.ToolClient for Bridge with fn call(self, name, arguments) {
  self.slots.acquire()
  defer self.slots.release()
  if self.next_id == 2147483647 {
    raise Failure::Failure("request id exhausted")
  }
  let id = self.next_id
  self.next_id += 1
  let waiter = @aqueue.Queue(kind=Blocking(1))
  self.pending[id] = waiter
  defer self.pending.remove(id)
  self.send(@protocol.Request(id~, name~, arguments~))
  waiter.get()
}

///|
impl @sdk.LogSink for Bridge with fn log(self, level, content) {
  self.send(@protocol.Log(level~, content~))
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
        Reply(id~, outcome~) => {
          let waiter = match self.pending.get(id) {
            Some(waiter) => waiter
            None => raise Failure::Failure("unknown or settled reply id")
          }
          // Remove before waking the caller, so a duplicate cannot be accepted.
          self.pending.remove(id)
          waiter.put(outcome)
        }
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
  let bridge = Bridge::{
    writer: @async.Mutex(),
    slots: @async.Semaphore(max_pending),
    pending: Map([]),
    max_frame_bytes,
    next_id: 1,
  }
  let ctx = @sdk.Context(tools=bridge, allowed=tools, logs=bridge)
  defer ctx.close()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => bridge.receive_replies())
    let outcome = handler(ctx, input)
    if !bridge.pending.is_empty() {
      raise Failure::Failure("handler returned with pending requests")
    }
    ctx.close()
    bridge.send(@protocol.Result(outcome~))
  })
}
