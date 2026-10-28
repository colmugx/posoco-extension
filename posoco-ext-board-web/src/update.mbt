///|
fn team_mcp_update(
  draft : TeamNames,
  role : String,
  update : (TeamMcp) -> TeamMcp,
) -> TeamNames {
  if role != "refiner" && role != "rd" && role != "set" && role != "te" {
    return draft
  }
  let mcp = draft.mcp.copy()
  let current = match mcp.get(role) {
    Some(value) => value
    None => TeamMcp::defaults()
  }
  mcp[role] = update(current)
  { ..draft, mcp }
}

///|
fn team_skills_update(
  draft : TeamNames,
  role : String,
  update : (TeamSkills) -> TeamSkills,
) -> TeamNames {
  if role != "refiner" && role != "rd" && role != "set" && role != "te" {
    return draft
  }
  let skills = draft.skills.copy()
  let current = match skills.get(role) {
    Some(value) => value
    None => TeamSkills::defaults()
  }
  skills[role] = update(current)
  { ..draft, skills }
}

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
                // Authoritative frames are the truth the stale veil waits
                // for; the first applied frame ends it.
                stale: false,
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
                close_settled_request_changes(
                  revalidate_inspector(close_missing_edit_target(model)),
                ),
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
      if !mutations_allowed(model) || draft_open(model) {
        // One editor at a time. A create draft retained after a rejected
        // command is reopened by the view from the same state.
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
    UserStoryChanged(value) =>
      (
        update_editor(model, editor => { ..editor, user_story: value, }),
        @rabbita.none,
      )
    ImplementationSuggestionsChanged(value) =>
      (
        update_editor(model, editor => {
          ..editor,
          implementation_suggestions: value,
        }),
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
    // Opening the inbox is what marks the visible worker updates as seen, so
    // the badge then counts only questions. Updates that arrive while it stays
    // open are unseen again until the next open.
    TicketDrawerOpened =>
      (
        {
          ..model,
          ticket_drawer: true,
          ticket_seen_updates: ticket_progress_seen(model.tickets.progress),
        },
        @rabbita.none,
      )
    TicketDrawerClosed => ({ ..model, ticket_drawer: false, }, @rabbita.none)
    TicketActivityOpened(task_id) =>
      ({ ..model, ticket_activity_task: Some(task_id), }, @rabbita.none)
    TicketActivityClosed =>
      ({ ..model, ticket_activity_task: None, }, @rabbita.none)
    TicketUpdatesDismissed =>
      if model.ticket_sending || !model.can_connect || !model.ticket_available {
        (model, @rabbita.none)
      } else {
        ({ ..model, ticket_sending: true, }, ticket_dismiss_updates(emit))
      }
    LiveOpened => ({ ..model, live_open: true, }, @rabbita.none)
    LiveClosed => ({ ..model, live_open: false, }, @rabbita.none)
    TeamOpened => {
      let draft = match model.tickets.team {
        Some(team) => team
        None => TeamNames::defaults()
      }
      (
        {
          ..model,
          team_open: true,
          team_draft: draft,
          team_profile_draft: model.tickets.profile,
          team_tab: "refiner",
        },
        @rabbita.none,
      )
    }
    TeamClosed => ({ ..model, team_open: false, }, @rabbita.none)
    TeamTabChanged(role) =>
      ({ ..model, team_tab: role }, @rabbita.none)
    TeamNameChanged(role, value) =>
      (
        {
          ..model,
          team_draft: match role {
            "refiner" => { ..model.team_draft, refiner: value }
            "rd" => { ..model.team_draft, rd: value }
            "set" => { ..model.team_draft, set: value }
            "te" => { ..model.team_draft, te: value }
            _ => model.team_draft
          },
        },
        @rabbita.none,
      )
    TeamMcpEnabledChanged(role, enabled) =>
      (
        {
          ..model,
          team_draft: team_mcp_update(model.team_draft, role, current => {
            { ..current, enabled }
          }),
        },
        @rabbita.none,
      )
    TeamMcpAllChanged(role, all) =>
      (
        {
          ..model,
          team_draft: team_mcp_update(model.team_draft, role, current => {
            { ..current, all }
          }),
        },
        @rabbita.none,
      )
    TeamMcpServerToggled(role, server) =>
      (
        {
          ..model,
          team_draft: team_mcp_update(model.team_draft, role, current => {
            let servers = if current.servers.contains(server) {
              current.servers.filter(item => item != server)
            } else {
              let next = current.servers.copy()
              next.push(server)
              next
            }
            { ..current, servers }
          }),
        },
        @rabbita.none,
      )
    TeamSkillsEnabledChanged(role, enabled) =>
      (
        {
          ..model,
          team_draft: team_skills_update(model.team_draft, role, current => {
            { ..current, enabled }
          }),
        },
        @rabbita.none,
      )
    TeamSkillsAllChanged(role, all) =>
      (
        {
          ..model,
          team_draft: team_skills_update(model.team_draft, role, current => {
            { ..current, all }
          }),
        },
        @rabbita.none,
      )
    TeamSkillToggled(role, name) =>
      (
        {
          ..model,
          team_draft: team_skills_update(model.team_draft, role, current => {
            let skills = if current.skills.contains(name) {
              current.skills.filter(item => item != name)
            } else {
              let next = current.skills.copy()
              next.push(name)
              next
            }
            { ..current, skills }
          }),
        },
        @rabbita.none,
      )
    TeamProfileChanged(id) =>
      (
        {
          ..model,
          team_profile_draft: match id {
            "document" => { id: "document", label: "Document" }
            "analysis" => { id: "analysis", label: "Analysis" }
            _ => WorkProfile::software()
          },
        },
        @rabbita.none,
      )
    TeamSaved =>
      if model.ticket_sending || !model.can_connect || !model.ticket_available {
        (model, @rabbita.none)
      } else if model.team_draft.refiner.trim().is_empty() ||
        model.team_draft.rd.trim().is_empty() ||
        model.team_draft.set.trim().is_empty() ||
        model.team_draft.te.trim().is_empty() {
        (
          {
            ..model,
            notice: Some(notice(Warning, "Every team name needs a value.")),
          },
          @rabbita.none,
        )
      } else {
        (
          { ..model, ticket_sending: true, },
          ticket_set_team(model.team_draft, model.team_profile_draft, emit),
        )
      }
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
    TicketAnsweredAsRefiner(question_id, answer) =>
      if model.ticket_sending ||
        !model.can_connect ||
        !model.ticket_available ||
        answer.trim().is_empty() {
        (model, @rabbita.none)
      } else {
        (
          { ..model, ticket_sending: true, },
          ticket_answer(
            question_id,
            TicketText(answer),
            emit,
            answered_by="refiner",
          ),
        )
      }
    RolePlanToggled(task_id, role, enabled) =>
      if model.ticket_sending || !model.can_connect || !model.ticket_available ||
        role == "rd" {
        (model, @rabbita.none)
      } else {
        let roles = match task_by_id(model.replica, task_id) {
          Some(task) => task.required_roles.map(team_role_id)
          None => ["rd", "set", "te"]
        }
        let next = if enabled {
          if roles.contains(role) { roles } else { roles + [role] }
        } else {
          roles.filter(item => item != role)
        }
        (
          { ..model, ticket_sending: true, },
          ticket_set_required_roles(task_id, next, emit),
        )
      }
    TicketRefinerRequested(question_id) =>
      if model.ticket_sending || !model.can_connect || !model.ticket_available {
        (model, @rabbita.none)
      } else {
        (
          { ..model, ticket_sending: true, },
          ticket_answer_as_refiner(question_id, emit),
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
    TicketRetry(task_id) =>
      // Retry never resumes the old child session: the host starts a fresh run.
      // It stays inert while a command is in flight, the socket cannot carry
      // it, the runtime is not advertised or this ticket still has a live run.
      if ticket_retry_blocked(model, task_id) {
        (model, @rabbita.none)
      } else {
        (
          {
            ..model,
            ticket_sending: true,
            last_status: "Retrying ticket " + task_id,
          },
          ticket_retry(task_id, emit),
        )
      }
    TicketResume(task_id) =>
      // Resume continues the durable child session the interrupted run already
      // owns, while Retry starts a fresh run and clears it. It is gated like
      // every other ticket command; the host still rejects a resume when no
      // session survived.
      if ticket_resume_blocked(model, task_id) {
        (model, @rabbita.none)
      } else {
        (
          {
            ..model,
            ticket_sending: true,
            last_status: "Resuming ticket " + task_id,
          },
          ticket_resume(task_id, emit),
        )
      }
    TicketSetModel(task_id, model_choice) =>
      // No optimistic model state: the control keeps rendering the
      // authoritative `task.model` until the host answers with a new state.
      // A running ticket, an in-flight command, an unavailable runtime or a
      // non-selectable catalog all block the command instead of queueing it.
      if model.ticket_sending ||
        !model.can_connect ||
        !model.ticket_available ||
        ticket_task_running(model, task_id) ||
        !ticket_model_catalog(model).selectable {
        (model, @rabbita.none)
      } else {
        (
          {
            ..model,
            ticket_sending: true,
            last_status: "Updating the model for ticket " + task_id,
          },
          ticket_set_model(task_id, model_choice, emit),
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
    ArchiveOpened => ({ ..model, archive_open: true, }, @rabbita.none)
    ArchiveClosed => ({ ..model, archive_open: false, }, @rabbita.none)
    DoneRequested(task_id) =>
      // Done leaves the flow; it is confirmed with its consequence instead
      // of firing straight from a card button.
      match task_by_id(model.replica, task_id) {
        Some(task) if step_reachable(task.stage, Done) &&
          mutations_allowed(model) =>
          ({ ..model, confirm: Some(ConfirmDone(task_id~)), }, @rabbita.none)
        _ => (model, @rabbita.none)
      }
    ConfirmDismissed => {
      // Dismissing a review confirmation drops the draft it created: the
      // decision was never sent.
      let review_draft = match model.confirm {
        Some(ConfirmReview) => None
        _ => model.review_draft
      }
      ({ ..model, confirm: None, review_draft, }, @rabbita.none)
    }
    ConfirmAccepted =>
      match model.confirm {
        Some(ConfirmDone(task_id~)) => {
          let model = { ..model, confirm: None, }
          submit_move(model, task_id, Done, emit, env)
        }
        Some(ConfirmReview) => {
          let model = { ..model, confirm: None, }
          submit_review(model, emit, env)
        }
        None => (model, @rabbita.none)
      }
    NoticeDismissed => ({ ..model, notice: None, }, @rabbita.none)
    NoticeActionInvoked =>
      // The undo re-enters the same guarded submit path as any move: gates
      // are re-checked against the live revision, never against the notice.
      match model.notice {
        Some({ action: Some(action), .. }) =>
          submit_move(model, action.task_id, action.move_to, emit, env)
        _ => (model, @rabbita.none)
      }
    KeyboardMove(step) =>
      match adjacent_task(model, step) {
        Some(id) => ({ ..model, selected_task: Some(id), }, @rabbita.none)
        None => (model, @rabbita.none)
      }
    TaskSelected(_)
    | InspectorClosed
    | DependenciesOpened
    | DependencyToggled(_, _)
    | DependencySelectionChanged(_)
    | DependenciesCleared
    | DependenciesRefreshed
    | DependenciesCancelled
    | DependenciesSubmitted
    | AttemptQueueOpened
    | AttemptQueueCancelled
    | AttemptFinishOpened(_)
    | AttemptFinishCancelled
    | AttemptKindChanged(_)
    | AttemptQueueSubmitted
    | AttemptStartRequested(_)
    | AttemptOutcomeChanged(_)
    | AttemptFinishSubmitted
    | ReviewDecide(_, _)
    | RequestChangesOpened(_)
    | RequestChangesFeedbackChanged(_)
    | RequestChangesSubmitted
    | RequestChangesCancelled => update_inspector(model, msg, emit, env)
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
