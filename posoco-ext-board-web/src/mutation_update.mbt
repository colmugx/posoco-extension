///|
/// An unconfirmed command invalidates the local baseline: the replica is
/// emptied so the next Hello requests a full snapshot, the pending record is
/// dropped without resending, drafts are kept and the existing bounded
/// reconnect scheduler is reused.
fn force_snapshot_resync(
  model : Model,
  emit : @rabbita.Emit[Msg],
) -> (Model, @rabbita.Cmd) {
  reconnect({ ..model, replica: @client.BoardReplica::empty(), }, emit)
}

///|
fn drop_pending_and_resync(
  model : Model,
  text : String,
  emit : @rabbita.Emit[Msg],
) -> (Model, @rabbita.Cmd) {
  force_snapshot_resync(
    { ..model, pending: None, notice: Some(notice(Warning, text)), },
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
  if !mutations_allowed(model) || editor.title.trim().is_empty() {
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
  let model = { ..model, pending: None, }
  let replica_stale = result.current_revision is Some(rev) &&
    rev != model.replica.revision()
  if result.accepted {
    let settled = "\{accepted_text(pending.kind)} "
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
      notice: Some(
        notice(
          Success,
          if replica_stale {
            "\{settled}Refreshing authoritative board state."
          } else {
            "\{settled}The board updates from the authoritative stream."
          },
        ),
      ),
    }
    if replica_stale {
      force_snapshot_resync(model, emit)
    } else {
      (model, @rabbita.none)
    }
  } else {
    reject_command(model, result, emit)
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
      drop_pending_and_resync(
        model, "The board could not confirm whether this change was saved. Refreshing authoritative state.",
        emit,
      )
    }
  } else if result.error is Some("revision_conflict") ||
    (!confirmed && result.current_revision is Some(_)) {
    drop_pending_and_resync(
      model, "The board changed while this change was in flight. Refreshing authoritative state.",
      emit,
    )
  } else {
    (
      { ..model, notice: Some(notice(Error, rejection_text(result.error))), },
      @rabbita.none,
    )
  }
}
