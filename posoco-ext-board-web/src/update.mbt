///|
/// Reconnect states the baseline explicitly: an ordinary disconnect keeps it
/// (the Hello replays on connect), invalidation or a first connect does not.
fn reconnect(model : Model, emit : @rabbita.Emit[Msg]) -> (Model, @rabbita.Cmd) {
  if model.retry_pending ||
    model.connection is ProtocolError(_) ||
    model.connection is Offline {
    return (model, @rabbita.none)
  }
  if model.retry_attempt >= 6 {
    return (
      {
        ..model,
        connection: Offline,
        retry_pending: false,
        last_status: "Connection failed; retry when the host is ready",
        notice: Some(
          notice(
            Warning,
            "Board connection failed. Retry when the host is ready.",
          ),
        ),
      },
      @rabbita.none,
    )
  }
  let delay = retry_delay(model.retry_attempt)
  let baseline = if model.replica.has_snapshot() {
    Retained
  } else if model.baseline is AwaitingFirst {
    AwaitingFirst
  } else {
    Invalidated
  }
  let last_status = match baseline {
    Retained =>
      "Reconnecting; the retained Board baseline stays and replays on reconnect"
    AwaitingFirst =>
      "Reconnecting; waiting for the first authoritative snapshot"
    Invalidated | Confirmed =>
      "Reconnecting; the stale Board baseline was discarded for a fresh snapshot"
  }
  (
    {
      ..model,
      connection: Reconnecting,
      baseline,
      retry_attempt: if model.retry_attempt < 6 {
        model.retry_attempt + 1
      } else {
        6
      },
      retry_pending: true,
      last_status,
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
    ConnectionStable(generation) =>
      if generation == model.generation &&
        model.connection is Online &&
        !model.retry_pending {
        ({ ..model, retry_attempt: 0, }, @rabbita.none)
      } else {
        (model, @rabbita.none)
      }
    ManualReconnect =>
      if !model.can_connect || model.pending is Some(_) {
        (model, @rabbita.none)
      } else {
        let generation = model.generation + 1
        (
          {
            ..model,
            generation,
            connection: Connecting,
            baseline: if model.replica.has_snapshot() {
              Retained
            } else {
              AwaitingFirst
            },
            retry_attempt: 0,
            retry_pending: false,
            notice: None,
            last_status: "Reconnecting after a manual retry",
          },
          @rabbita.batch([
            @websocket.close("board"),
            connect(env.url, generation, emit),
          ]),
        )
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
        Opened => {
          // An up-to-date baseline can reconnect with no replay frames.
          // Opening a socket alone never establishes a fresh baseline, so the
          // connection is only Online when a baseline is retained, and the
          // status explains that the idle open may stay silent.
          let retained = model.replica.has_snapshot()
          let last_status = if retained {
            "Board baseline retained; the open connection replays only missed changes"
          } else if model.baseline is Invalidated {
            "Waiting for a fresh authoritative snapshot"
          } else {
            "Waiting for the first authoritative snapshot"
          }
          let next = {
            ..model,
            connection: if retained {
              Online
            } else {
              model.connection
            },
            baseline: if retained {
              Retained
            } else {
              model.baseline
            },
            last_status,
          }
          let send = @websocket.send(
            "board",
            Text(hello_payload(model.replica)),
            failed=_ => emit(TransportFailed(generation)),
          )
          // A retained baseline may legitimately receive zero frames, so an
          // open socket is not proof by itself. Only a connection that stays
          // open for a moment resets the bounded reconnect delay; a server
          // that accepts and immediately drops keeps escalating.
          let cmds = if retained {
            @rabbita.batch([
              send,
              @rabbita.delay(emit(ConnectionStable(generation)), 1000),
            ])
          } else {
            send
          }
          (next, cmds)
        }
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
          match ticket_frame(text) {
            Some(TicketSnapshot(tickets)) =>
              return (apply_ticket_state(model, tickets), @rabbita.none)
            Some(TicketOutcome(ok, reason, tickets)) =>
              return (
                apply_ticket_outcome(model, ok, reason, tickets),
                @rabbita.none,
              )
            None => ()
          }
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
                baseline: if model.replica.has_snapshot() {
                  Confirmed
                } else {
                  model.baseline
                },
                retry_attempt: if snapshot {
                  0
                } else {
                  model.retry_attempt
                },
                last_status: if model.replica.has_snapshot() {
                  "Authoritative Board state"
                } else if model.baseline is Invalidated {
                  "Waiting for a fresh authoritative snapshot"
                } else {
                  "Waiting for the first authoritative snapshot"
                },
              }
              (
                revalidate_inspector(close_missing_edit_target(model)),
                @rabbita.none,
              )
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
      if draft_open(model) || !mutations_allowed(model) {
        (model, @rabbita.none)
      } else {
        ({ ..model, editor: Some(Editor::create()), }, @rabbita.none)
      }
    EditOpened(task_id) =>
      // One editor at a time; the authoritative record must exist.
      if draft_open(model) || !mutations_allowed(model) {
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
    MoveRequested(task_id, to) =>
      if draft_open(model) {
        (model, @rabbita.none)
      } else {
        submit_move(model, task_id, to, emit, env)
      }
    // Local view filters: they only change how the replica renders and never
    // touch the authoritative state, the selection or any draft.
    FilterQueryChanged(value) =>
      (
        { ..model, task_filter: { ..model.task_filter, query: value, }, },
        @rabbita.none,
      )
    FilterPriorityChanged(value) =>
      (
        {
          ..model,
          task_filter: {
            ..model.task_filter,
            priority: filter_priority_from_wire(
              value,
              model.task_filter.priority,
            ),
          },
        },
        @rabbita.none,
      )
    FilterStageChanged(value) =>
      (
        {
          ..model,
          task_filter: {
            ..model.task_filter,
            stage: filter_stage_from_wire(value, model.task_filter.stage),
          },
        },
        @rabbita.none,
      )
    FiltersCleared =>
      ({ ..model, task_filter: TaskFilter::none(), }, @rabbita.none)
    TicketDrawerToggled =>
      ({ ..model, ticket_drawer: !model.ticket_drawer, }, @rabbita.none)
    TicketDraftChanged(question_id, value) => {
      let drafts = model.ticket_drafts.copy()
      drafts[question_id] = value
      ({ ..model, ticket_drafts: drafts, }, @rabbita.none)
    }
    TicketAnswered(question_id, answer) =>
      if model.ticket_sending || !model.can_connect || !model.ticket_available {
        (model, @rabbita.none)
      } else {
        (
          { ..model, ticket_sending: true, },
          ticket_answer(question_id, answer, emit),
        )
      }
    TicketShape(task_id) =>
      if model.ticket_sending || !model.can_connect || !model.ticket_available {
        (model, @rabbita.none)
      } else {
        (
          {
            ..model,
            ticket_sending: true,
            last_status: "Shaping ticket " + task_id,
          },
          ticket_shape(task_id, emit),
        )
      }
    TicketRun(task_id) =>
      if model.ticket_sending || !model.can_connect || !model.ticket_available {
        (model, @rabbita.none)
      } else {
        (
          {
            ..model,
            ticket_sending: true,
            last_status: "Starting ticket " + task_id,
          },
          ticket_run(task_id, emit),
        )
      }
    TicketRunReady =>
      if model.ticket_sending || !model.can_connect || !model.ticket_available {
        (model, @rabbita.none)
      } else if ready_ticket_count(model) == 0 {
        (
          {
            ..model,
            notice: Some(notice(Warning, "No Ready ticket is waiting.")),
          },
          @rabbita.none,
        )
      } else {
        (
          {
            ..model,
            ticket_sending: true,
            last_status: "Starting the next Ready ticket",
          },
          ticket_run_ready(emit),
        )
      }
    TicketResultDismissed(task_id) =>
      if model.ticket_sending || !model.can_connect || !model.ticket_available {
        (model, @rabbita.none)
      } else {
        ({ ..model, ticket_sending: true, }, ticket_dismiss(task_id, emit))
      }
    TicketResult(ok, reason, tickets) =>
      (apply_ticket_outcome(model, ok, reason, tickets), @rabbita.none)
    NoticeDismissed => ({ ..model, notice: None, }, @rabbita.none)
    TaskSelected(_)
    | InspectorClosed
    | DependenciesOpened
    | DependencyToggled(_, _)
    | DependencySelectionChanged(_)
    | DependenciesCleared
    | DependenciesRefreshed
    | DependenciesCancelled
    | DependenciesSubmitted
    | DependencyDraftReturned
    | AttemptQueueOpened
    | AttemptQueueCancelled
    | AttemptDraftReturned
    | AttemptFinishOpened(_)
    | AttemptFinishCancelled
    | AttemptKindChanged(_)
    | AttemptQueueSubmitted
    | AttemptStartRequested(_)
    | AttemptOutcomeChanged(_)
    | AttemptFinishSubmitted
    | ReviewOpened(_)
    | ReviewCancelled
    | ReviewDecisionChanged(_)
    | ReviewDraftReturned
    | ReviewSubmitted => update_inspector(model, msg, emit, env)
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
