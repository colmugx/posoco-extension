///|
/// An unconfirmed command invalidates the local baseline: the replica is
/// emptied so the next Hello requests a full snapshot, the pending record is
/// dropped without resending, drafts are kept and the existing bounded
/// reconnect scheduler is reused.
fn force_snapshot_resync(
  model : Model,
  emit : @rabbita.Emit[Msg],
) -> (Model, @rabbita.Cmd) {
  reconnect(
    {
      ..model,
      replica: @client.BoardReplica::empty(),
      stale: false,
      optimistic: None,
    },
    emit,
  )
}

///|
/// A revision conflict or uncertain durability keeps the last good snapshot
/// under the stale veil instead of blanking the board: the reconnect reuses
/// the baseline-aware Hello, the server replays the missed contiguous frames,
/// and the next applied frame clears the flag. The pending record and the
/// move overlay die with the rejected command.
fn keep_baseline_and_resync(
  model : Model,
  notice : Notice,
  emit : @rabbita.Emit[Msg],
) -> (Model, @rabbita.Cmd) {
  reconnect(
    {
      ..model,
      pending: None,
      stale: true,
      optimistic: None,
      notice: Some(notice),
    },
    emit,
  )
}

///|
fn drop_pending_and_resync(
  model : Model,
  text : String,
  emit : @rabbita.Emit[Msg],
) -> (Model, @rabbita.Cmd) {
  force_snapshot_resync(
    {
      ..model,
      pending: None,
      optimistic: None,
      notice: Some(notice(Warning, text)),
    },
    emit,
  )
}

///|
/// Stamp the single pending correlation record and hand the encoded frame to
/// the send helper. No queue, no retry: a new submit is impossible while a
/// command is pending.
fn dispatch_command(
  model : Model,
  command : @protocol.BoardClientCommand,
  kind : PendingKind,
  emit : @rabbita.Emit[Msg],
) -> (Model, @rabbita.Cmd) {
  let model = {
    ..model,
    pending: Some({
      command_id: command.command_id,
      kind,
      revision: command.expected_revision,
    }),
  }
  (model, send_command(model.generation, command, emit))
}

///|
/// Shared submit guards: authoritative replica, no in-flight command, a
/// trimmed non-empty title and an injectable identifier. Guards are quiet;
/// the view keeps the controls disabled in every disallowed state.
fn submit_editor(
  model : Model,
  editor : Editor,
  emit : @rabbita.Emit[Msg],
  env : Env,
) -> (Model, @rabbita.Cmd) {
  let idea = if editor.mode is CreateMode {
    editor.title + editor.description
  } else {
    editor.title
  }
  if !mutations_allowed(model) || idea.trim().is_empty() {
    return (model, @rabbita.none)
  }
  if editor.mode is EditMode(task_id~) &&
    task_by_id(model.replica, task_id) is None {
    return (
      {
        ..model,
        editor: None,
        notice: Some(notice(Error, "The task no longer exists.")),
      },
      @rabbita.none,
    )
  }
  guard (env.uuid)() is Some(uuid) else {
    return (
      {
        ..model,
        notice: Some(
          notice(
            Error,
            "This browser cannot generate the identifiers required to submit changes.",
          ),
        ),
      },
      @rabbita.none,
    )
  }
  let revision = model.replica.revision()
  let (command, kind) = match editor.mode {
    CreateMode => (create_command(uuid, revision, editor), PendingCreate)
    EditMode(task_id~) =>
      (update_command(uuid, revision, task_id, editor), PendingEdit(task_id~))
  }
  dispatch_command(model, command, kind, emit)
}

///|
fn submit_move(
  model : Model,
  task_id : String,
  to : @client.ClientBoardStage,
  emit : @rabbita.Emit[Msg],
  env : Env,
) -> (Model, @rabbita.Cmd) {
  if !mutations_allowed(model) {
    return (model, @rabbita.none)
  }
  guard (env.uuid)() is Some(uuid) else {
    return (
      {
        ..model,
        notice: Some(
          notice(
            Error,
            "This browser cannot generate the identifiers required to submit changes.",
          ),
        ),
      },
      @rabbita.none,
    )
  }
  if to is @client.Ready {
    match task_by_id(model.replica, task_id) {
      Some(task) =>
        match ready_blocked_hint(task) {
          Some(hint) =>
            return (
              { ..model, notice: Some(notice(Error, hint)), },
              @rabbita.none,
            )
          None => ()
        }
      None => ()
    }
  }
  // The move renders optimistically from the task's current stage; the
  // replica itself only changes when the authoritative stream says so.
  let model = match task_by_id(model.replica, task_id) {
    Some(task) if task.stage != to =>
      { ..model, optimistic: Some({ task_id, from: task.stage, to, }), }
    _ => model
  }
  dispatch_command(
    model,
    move_command(uuid, model.replica.revision(), task_id, to),
    PendingMove(task_id~, to~),
    emit,
  )
}

///|
/// Settle one correlated command result. Results never project replica
/// state: an accepted command only clears the pending record, closes the
/// matching editor and reports success, while any reported revision other
/// than the replica's own marks the baseline stale and forces a snapshot
/// resync — even for accepted commands. Rejections keep the draft and never
/// roll back or resend.
fn settle_command(
  model : Model,
  result : @protocol.BoardCommandResult,
  emit : @rabbita.Emit[Msg],
) -> (Model, @rabbita.Cmd) {
  guard model.pending is Some(pending) else { return (model, @rabbita.none) }
  if result.command_id != pending.command_id {
    return (model, @rabbita.none)
  }
  // The move overlay projected a stage the stream has now confirmed or
  // refused; either way the replica is the only visible truth again.
  let settled_move = model.optimistic
  let model = { ..model, pending: None, optimistic: None, }
  let replica_stale = result.current_revision is Some(rev) &&
    rev != model.replica.revision()
  if result.accepted {
    let settled = "\{accepted_text(pending.kind)} "
    let text = if replica_stale {
      "\{settled}Refreshing authoritative board state."
    } else {
      "\{settled}The board updates from the authoritative stream."
    }
    let model = {
      ..model,
      editor: close_matching_editor(model.editor, pending.kind),
      dependency_editor: settle_dependency_editor(
        model.dependency_editor,
        pending.kind,
      ),
      attempt_draft: settle_attempt_draft(model.attempt_draft, pending.kind),
      finish_draft: settle_finish_draft(model.finish_draft, pending.kind),
      review_draft: settle_review_draft(model.review_draft, pending.kind),
      notice: Some(move_undo_notice(pending, settled_move, text, replica_stale)),
    }
    if replica_stale {
      keep_baseline_and_resync(model, model.notice.unwrap(), emit)
    } else {
      (model, @rabbita.none)
    }
  } else {
    reject_command(model, result, emit)
  }
}

///|
/// An accepted move offers its own undo when the board's FSM allows stepping
/// straight back to where the task came from; every other command settles
/// with a plain success notice, and a stale board never offers an undo that
/// the resync is about to supersede.
fn move_undo_notice(
  pending : PendingCommand,
  optimistic : OptimisticMove?,
  text : String,
  replica_stale : Bool,
) -> Notice {
  match (pending.kind, optimistic) {
    (PendingMove(..), Some(pending_move)) if !replica_stale &&
      step_reachable(pending_move.to, pending_move.from) =>
      {
        ..notice(Success, text),
        action: Some({
          label: "Undo",
          task_id: pending_move.task_id,
          move_to: pending_move.from,
        }),
      }
    _ => notice(Success, text)
  }
}

///|
/// Rejection semantics. A revision conflict — or any reported revision that
/// disagrees with the replica — forces an empty replica plus the existing
/// reconnect backoff so a fresh snapshot settles the board. Uncertain
/// durability retains the event state only when the reported revision still
/// matches. Every other stable code keeps the baseline, keeps the draft and
/// shows mapped safe text; nothing is retried or rolled back.
fn reject_command(
  model : Model,
  result : @protocol.BoardCommandResult,
  emit : @rabbita.Emit[Msg],
) -> (Model, @rabbita.Cmd) {
  let confirmed = result.current_revision is Some(rev) &&
    rev == model.replica.revision()
  if result.error is Some("durability_uncertain") {
    if confirmed {
      (
        {
          ..model,
          notice: Some(
            notice(
              Warning,
              "The board could not confirm whether this change was saved. The current board state is kept.",
            ),
          ),
        },
        @rabbita.none,
      )
    } else {
      keep_baseline_and_resync(
        model,
        notice(
          Warning,
          "The board could not confirm whether this change was saved. Refreshing authoritative state.",
        ),
        emit,
      )
    }
  } else if result.error is Some("revision_conflict") ||
    (!confirmed && result.current_revision is Some(_)) {
    keep_baseline_and_resync(
      model,
      notice(
        Warning,
        "The board changed while this change was in flight. Refreshing authoritative state.",
      ),
      emit,
    )
  } else {
    (
      { ..model, notice: Some(notice(Error, rejection_text(result.error))), },
      @rabbita.none,
    )
  }
}
