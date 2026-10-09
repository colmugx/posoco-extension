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
  env : Env,
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
      (model, connect(env.url, generation, emit))
    }
    TransportFailed(generation) =>
      if generation != model.generation {
        (model, @rabbita.none)
      } else if model.pending is Some(_) {
        drop_pending_and_resync(
          model, "Connection was lost before the command settled; Board state is being reconciled.",
          emit,
        )
      } else {
        reconnect(model, emit)
      }
    SendFailed(generation, command_id) => {
      // The send failure must correlate both the connection generation and
      // the command id, so a callback from a replaced socket or a replaced
      // command can never clear the current pending record.
      if generation != model.generation {
        return (model, @rabbita.none)
      }
      guard model.pending is Some(pending) && pending.command_id == command_id else {
        return (model, @rabbita.none)
      }
      drop_pending_and_resync(
        model, "The board connection dropped before your change was confirmed.",
        emit,
      )
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
        Closed(_) | Errored =>
          // With a command in flight the baseline is unconfirmed and the
          // replica is dropped; an ordinary disconnect preserves it and the
          // baseline-aware Hello replays the stream instead.
          if model.pending is Some(_) {
            drop_pending_and_resync(
              model, "The board connection dropped before your change was confirmed.",
              emit,
            )
          } else {
            reconnect(model, emit)
          }
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
            Applied => {
              let model = {
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
              }
              (close_missing_edit_target(model), @rabbita.none)
            }
            Duplicate => (model, @rabbita.none)
            CommandSettled(result) => settle_command(model, result, emit)
            NeedsSnapshot(_) =>
              // Resynchronization discards the baseline; a pending command's
              // result can no longer settle against it, so the record must
              // not survive stale.
              if model.pending is Some(_) {
                drop_pending_and_resync(
                  model, "The board lost synchronization before your change was confirmed.",
                  emit,
                )
              } else {
                reconnect(model, emit)
              }
            TerminalProtocolError(code) => {
              let had_pending = model.pending is Some(_)
              (
                {
                  ..model,
                  connection: ProtocolError(code),
                  replica: if had_pending {
                    @client.BoardReplica::empty()
                  } else {
                    model.replica
                  },
                  retry_pending: false,
                  // Terminal errors stop retries; the pending record must not
                  // outlive the connection that could settle it.
                  pending: None,
                  notice: if had_pending {
                    Some(
                      notice(
                        Warning,
                        "The board connection stopped. Your change was not confirmed.",
                      ),
                    )
                  } else {
                    model.notice
                  },
                  last_status: "Board protocol error; automatic reconnect stopped",
                },
                @websocket.close("board"),
              )
            }
          }
        }
      }
    }
    CreateOpened =>
      if model.editor is Some(_) || !mutations_allowed(model) {
        (model, @rabbita.none)
      } else {
        ({ ..model, editor: Some(Editor::create()), }, @rabbita.none)
      }
    EditOpened(task_id) =>
      // One editor at a time; the authoritative record must exist.
      if model.editor is Some(_) || !mutations_allowed(model) {
        (model, @rabbita.none)
      } else {
        match task_by_id(model.replica, task_id) {
          Some(task) =>
            (
              {
                ..model,
                editor: Some(Editor::from_task(EditMode(task_id~), task)),
              },
              @rabbita.none,
            )
          None =>
            (
              {
                ..model,
                notice: Some(
                  notice(Error, "That task is no longer on the board."),
                ),
              },
              @rabbita.none,
            )
        }
      }
    EditorCancelled =>
      if model.pending is Some(_) {
        (model, @rabbita.none)
      } else {
        ({ ..model, editor: None, }, @rabbita.none)
      }
    TitleChanged(value) =>
      (
        update_editor(model, editor => { ..editor, title: value, }),
        @rabbita.none,
      )
    DescriptionChanged(value) =>
      (
        update_editor(model, editor => { ..editor, description: value, }),
        @rabbita.none,
      )
    PriorityChanged(value) =>
      (
        update_editor(model, editor => {
          match priority_from_wire(value) {
            Some(priority) => { ..editor, priority, }
            None => editor
          }
        }),
        @rabbita.none,
      )
    DefinitionOfDoneChanged(value) =>
      (
        update_editor(model, editor => { ..editor, definition_of_done: value, }),
        @rabbita.none,
      )
    SubmitRequested =>
      match model.editor {
        Some(editor) => submit_editor(model, editor, emit, env)
        None => (model, @rabbita.none)
      }
    MoveRequested(task_id, to) => submit_move(model, task_id, to, emit, env)
  }
}

///|
/// Draft edits only apply while an editor is open; they never reopen one.
fn update_editor(model : Model, change : (Editor) -> Editor) -> Model {
  if model.pending is Some(_) {
    return model
  }
  match model.editor {
    Some(editor) => { ..model, editor: Some(change(editor)), }
    None => model
  }
}
