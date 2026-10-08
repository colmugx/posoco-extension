///|
priv suberror BoardFrameError {
  ExpectedText
  FrameTooLarge
}

///|
async fn board_read_text(ws : @websocket.Conn) -> String {
  let message = ws.recv()
  guard message.kind is Text else { raise ExpectedText }
  let bytes : Array[Byte] = []
  while message.read_some(max_len=8193 - bytes.length()) is Some(chunk) {
    for byte in chunk {
      bytes.push(byte)
    }
    if bytes.length() > 8192 {
      raise FrameTooLarge
    }
  }
  @utf8.decode(Bytes::from_array(bytes))
}

///|
async fn board_receive_hello(
  ws : @websocket.Conn,
) -> Result[@protocol.BoardHello, @protocol.BoardServerFrame] {
  let raw = @async.with_timeout(5000, () => board_read_text(ws)) catch {
    @async.TimeoutError =>
      return Err(
        @protocol.Error(
          code="hello_timeout",
          message="Hello required within 5 seconds",
        ),
      )
    ExpectedText =>
      return Err(
        @protocol.Error(code="expected_text", message="Hello must be text"),
      )
    FrameTooLarge =>
      return Err(
        @protocol.Error(
          code="frame_too_large",
          message="Client frames are limited to 8192 bytes",
        ),
      )
    error => raise error
  }
  match @protocol.decode_client_frame(raw) {
    Ok(Hello(hello)) => Ok(hello)
    Ok(Command(_)) =>
      Err(
        @protocol.Error(
          code="hello_required",
          message="First frame must be Hello",
        ),
      )
    Err(UnsupportedVersion(..)) =>
      Err(
        @protocol.Error(
          code="unsupported_version",
          message="Expected protocol version 1",
        ),
      )
    Err(_) =>
      Err(
        @protocol.Error(code="invalid_hello", message="Invalid Hello or cursor"),
      )
  }
}

///|
async fn board_write_frame(
  ws : @websocket.Conn,
  frame : @protocol.BoardServerFrame,
) -> Unit {
  @async.with_timeout(1000, () => {
    ws.send_text(@protocol.encode_server_frame(frame))
  })
}

///|
async fn board_client_sender(
  ws : @websocket.Conn,
  client : @backend.BoardSubscription,
) -> Unit {
  client.pump(frame => board_write_frame(ws, frame))
}

///|
/// Best-effort explicit resync frame. The connection always closes after
/// it; a fragmented interrupted write closes silently instead.
async fn NativeBoardWebServer::resync(
  self : NativeBoardWebServer,
  ws : @websocket.Conn,
  reason : String,
) -> Unit {
  let current_seq = match self.backend {
    Some(backend) => backend.current_seq()
    None => 0L
  }
  board_write_frame(ws, @protocol.ResyncRequired(reason~, current_seq~)) catch {
    _ => ()
  }
}

///|
/// Authoritative bootstrap of a `SnapshotRequired` subscription. The
/// backend is awaited only after synchronous registration, so live events
/// accumulate in the mailbox while the coordinator settles; the installed
/// snapshot carries the boundary and the sender drops stale mailbox
/// duplicates. Any failure sends one resync frame and closes: no snapshot
/// is ever fabricated here. A mailbox overflow while the backend is
/// awaited resyncs with `client_queue_overflow` before anything is
/// installed or sent: the answered snapshot is already stale by the time it
/// arrives.
async fn NativeBoardWebServer::bootstrap_client(
  self : NativeBoardWebServer,
  ws : @websocket.Conn,
  client : @backend.BoardSubscription,
  backend : @backend.BoardBackend,
) -> Bool {
  match backend.bootstrap_snapshot() {
    Ok(snapshot) => {
      // Live events queued during the provider await may have overflowed
      // the bounded mailbox. An overflowed bootstrap must never install or
      // send the now-stale snapshot: one explicit resync closes instead.
      if client.resync_required() is Some(_) {
        self.resync(ws, "client_queue_overflow")
        return false
      }
      client.install_snapshot(snapshot)
      true
    }
    Err(reason) => {
      self.resync(ws, reason)
      false
    }
  }
}

///|
async fn NativeBoardWebServer::serve_ws(
  self : NativeBoardWebServer,
  ws : @websocket.Conn,
) -> Unit {
  let backend = match self.backend {
    Some(backend) => backend
    None => return
  }
  let first = board_receive_hello(ws) catch { _ => return }
  let hello = match first {
    Ok(hello) => hello
    Err(frame) => {
      board_write_frame(ws, frame) catch {
        _ => ()
      }
      return
    }
  }
  // Registration is synchronous; the authoritative bootstrap of a
  // snapshot-required plan is the only awaited step.
  let client = backend.subscribe(hello.last_seq, hello.has_board_snapshot)
  defer backend.unsubscribe(client)
  if client.plan is SnapshotRequired {
    if !(self.bootstrap_client(ws, client, backend) catch { _ => false }) {
      return
    }
  }
  // any owns and joins both local tasks on success, failure and cancellation.
  @async.any([
    () => board_client_sender(ws, client),
    () => {
      for ;; {
        let raw = board_read_text(ws)
        let frame = match @protocol.decode_client_frame(raw) {
          Ok(Command(command)) =>
            // The backend owns the authoritative answer; every committed
            // event is already enqueued before the result frame is built.
            // The result is enqueued only for this connection and never
            // published into the retained stream.
            @protocol.CommandResult(backend.handle_command(command))
          _ =>
            @protocol.Error(
              code="invalid_frame",
              message="Expected Command after Hello",
            )
        }
        backend.enqueue_local(client, frame)
      }
    },
  ]) catch {
    _ => ()
  }
}
