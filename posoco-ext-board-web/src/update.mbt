///|
fn reconnect(model : Model, emit : @rabbita.Emit[Msg]) -> (Model, @rabbita.Cmd) {
  if model.retry_pending ||
    model.connection is ProtocolError(_) ||
    model.connection is Offline {
    return (model, @rabbita.none)
  }
  let delay = retry_delay(model.retry_attempt)
  (
    {
      ..model,
      connection: Reconnecting,
      retry_attempt: if model.retry_attempt < 6 {
        model.retry_attempt + 1
      } else {
        6
      },
      retry_pending: true,
      last_status: "Reconnecting to authoritative Board state",
    },
    @rabbita.batch([
      @websocket.close("board"),
      @rabbita.delay(emit(Retry(model.generation)), delay),
    ]),
  )
}

///|
fn update(
  model : Model,
  msg : Msg,
  emit : @rabbita.Emit[Msg],
  url : String,
) -> (Model, @rabbita.Cmd) {
  match msg {
    Retry(generation) => {
      if generation != model.generation ||
        !model.retry_pending ||
        model.connection is ProtocolError(_) {
        return (model, @rabbita.none)
      }
      let generation = model.generation + 1
      let model = { ..model, generation, retry_pending: false, }
      (model, connect(url, generation, emit))
    }
    TransportFailed(generation) =>
      if generation != model.generation {
        (model, @rabbita.none)
      } else {
        reconnect(model, emit)
      }
    SocketEvent(generation, event) => {
      // Late callbacks from replaced sockets must not affect the current one.
      if generation != model.generation ||
        model.retry_pending ||
        model.connection is ProtocolError(_) {
        return (model, @rabbita.none)
      }
      match event {
        Opened =>
          (
            {
              ..model,
              // An up-to-date baseline can reconnect with no replay frames.
              // Opening a socket alone never establishes a fresh baseline.
              connection: if model.replica.has_snapshot() {
                Online
              } else {
                model.connection
              },
            },
            @websocket.send("board", Text(hello_payload(model.replica)), failed=_ => {
              emit(TransportFailed(generation))
            }),
          )
        Closed(_) | Errored => reconnect(model, emit)
        Message(text) => {
          // Keep the previous Rabbita model immutable so equality can detect
          // changes even when only a nested task/attempt record changes.
          let replica = model.replica.copy()
          let (outcome, snapshot) = match @protocol.decode_server_frame(text) {
            Ok(frame) => (replica.apply_frame(frame), frame is Snapshot(_))
            Err(_) => (replica.apply_text(text), false)
          }
          let model = { ..model, replica, }
          match outcome {
            Applied =>
              (
                {
                  ..model,
                  connection: if model.replica.has_snapshot() {
                    Online
                  } else {
                    model.connection
                  },
                  retry_attempt: if snapshot {
                    0
                  } else {
                    model.retry_attempt
                  },
                  last_status: if model.replica.has_snapshot() {
                    "Authoritative Board state"
                  } else {
                    "Waiting for Board snapshot"
                  },
                },
                @rabbita.none,
              )
            Duplicate | CommandSettled(_) => (model, @rabbita.none)
            NeedsSnapshot(_) => reconnect(model, emit)
            TerminalProtocolError(code) =>
              (
                {
                  ..model,
                  connection: ProtocolError(code),
                  retry_pending: false,
                  last_status: "Board protocol error; automatic reconnect stopped",
                },
                @websocket.close("board"),
              )
          }
        }
      }
    }
  }
}
