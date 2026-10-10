///|
fn update_inspector(
  model : Model,
  msg : Msg,
  emit : @rabbita.Emit[Msg],
  env : Env,
) -> (Model, @rabbita.Cmd) {
  match msg {
    TaskSelected(id) =>
      if task_by_id(model.replica, id) is Some(_) {
        ({ ..model, selected_task: Some(id), }, @rabbita.none)
      } else {
        (model, @rabbita.none)
      }
    InspectorClosed => ({ ..model, selected_task: None, }, @rabbita.none)
    DependenciesOpened => {
      if !mutations_allowed(model) || draft_open(model) {
        return (model, @rabbita.none)
      }
      guard inspector_task(model) is Some(task) else {
        return (model, @rabbita.none)
      }
      (
        { ..model, dependency_editor: Some(DependencyDraft::from_task(task)), },
        @rabbita.none,
      )
    }
    DependencyToggled(id, checked) =>
      (dependency_toggle(model, id, checked), @rabbita.none)
    DependencySelectionChanged(id) => {
      guard model.dependency_editor is Some(draft) else {
        return (model, @rabbita.none)
      }
      (
        dependency_toggle(model, id, !draft.dependencies.contains(id)),
        @rabbita.none,
      )
    }
    DependenciesCleared => {
      guard model.dependency_editor is Some(draft) &&
        dependency_editable(model, draft) else {
        return (model, @rabbita.none)
      }
      (
        { ..model, dependency_editor: Some({ ..draft, dependencies: [], }), },
        @rabbita.none,
      )
    }
    DependenciesRefreshed => (dependency_refresh(model), @rabbita.none)
    DependenciesCancelled =>
      if model.pending is Some(_) {
        (model, @rabbita.none)
      } else {
        ({ ..model, dependency_editor: None, }, @rabbita.none)
      }
    DependencyDraftReturned =>
      match model.dependency_editor {
        Some(draft) =>
          ({ ..model, selected_task: Some(draft.task_id), }, @rabbita.none)
        None => (model, @rabbita.none)
      }
    DependenciesSubmitted => submit_dependencies(model, emit, env)
    AttemptQueueOpened =>
      // One draft at a time, through the same mutation gate.
      if draft_open(model) || !mutations_allowed(model) {
        (model, @rabbita.none)
      } else {
        guard inspector_task(model) is Some(task) else {
          return (model, @rabbita.none)
        }
        guard (env.uuid)() is Some(uuid) && uuid != "" else {
          return (missing_uuid_notice(model), @rabbita.none)
        }
        (
          {
            ..model,
            attempt_draft: Some({
              task_id: task.id,
              attempt_id: "attempt-" + uuid,
              kind: @client.Discuss,
            }),
          },
          @rabbita.none,
        )
      }
    AttemptQueueCancelled =>
      if model.pending is Some(_) {
        (model, @rabbita.none)
      } else {
        ({ ..model, attempt_draft: None, }, @rabbita.none)
      }
    AttemptDraftReturned => {
      let task_id = match (model.attempt_draft, model.finish_draft) {
        (Some(draft), _) => Some(draft.task_id)
        (_, Some(draft)) => Some(draft.task_id)
        _ => None
      }
      ({ ..model, selected_task: task_id, }, @rabbita.none)
    }
    AttemptKindChanged(value) =>
      (
        update_attempt_draft(model, draft => {
          match attempt_kind_from_wire(value) {
            Some(kind) => { ..draft, kind, }
            None => draft
          }
        }),
        @rabbita.none,
      )
    AttemptQueueSubmitted => submit_attempt_queue(model, emit, env)
    AttemptStartRequested(attempt_id) =>
      submit_attempt_start(model, attempt_id, emit, env)
    AttemptFinishOpened(attempt_id) => {
      guard attempt_controls_allowed(model) &&
        attempt_by_id(model.replica, attempt_id) is Some(attempt) &&
        model.selected_task == Some(attempt.task_id) &&
        task_by_id(model.replica, attempt.task_id) is Some(_) &&
        attempt_finishable(attempt.status) else {
        return (model, @rabbita.none)
      }
      (
        {
          ..model,
          finish_draft: Some({
            task_id: attempt.task_id,
            attempt_id,
            outcome: None,
          }),
        },
        @rabbita.none,
      )
    }
    AttemptFinishCancelled =>
      if model.pending is Some(_) {
        (model, @rabbita.none)
      } else {
        ({ ..model, finish_draft: None, }, @rabbita.none)
      }
    AttemptOutcomeChanged(value) => {
      guard model.finish_draft is Some(draft) &&
        finish_draft_editable(model, draft) else {
        return (model, @rabbita.none)
      }
      let outcome = if value == "" {
        None
      } else {
        guard attempt_outcome_from_wire(value) is Some(outcome) else {
          return (model, @rabbita.none)
        }
        Some(outcome)
      }
      ({ ..model, finish_draft: Some({ ..draft, outcome, }), }, @rabbita.none)
    }
    AttemptFinishSubmitted => submit_attempt_finish(model, emit, env)
    _ => (model, @rabbita.none)
  }
}

///|
/// Draft edits only apply while an attempt draft is open; they never reopen
/// or resend anything.
fn update_attempt_draft(
  model : Model,
  change : (AttemptDraft) -> AttemptDraft,
) -> Model {
  match model.attempt_draft {
    Some(draft) if attempt_draft_editable(model, draft) =>
      { ..model, attempt_draft: Some(change(draft)), }
    _ => model
  }
}

///|
fn submit_dependencies(
  model : Model,
  emit : @rabbita.Emit[Msg],
  env : Env,
) -> (Model, @rabbita.Cmd) {
  guard model.dependency_editor is Some(draft) &&
    dependency_editable(model, draft) else {
    return (model, @rabbita.none)
  }
  if dependency_conflict(model, draft) {
    return (
      {
        ..model,
        notice: Some(
          notice(
            Warning,
            "Dependencies changed while you were editing. Reload the latest dependencies before saving.",
          ),
        ),
      },
      @rabbita.none,
    )
  }
  guard (env.uuid)() is Some(uuid) && uuid != "" else {
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
  let command = @client.set_task_dependencies_command(
    "cmd-" + uuid,
    model.replica.revision(),
    id=draft.task_id,
    dependencies=draft.dependencies,
  )
  dispatch_command(
    model,
    command,
    PendingDependencies(task_id=draft.task_id),
    emit,
  )
}

///|
fn settle_dependency_editor(
  draft : DependencyDraft?,
  kind : PendingKind,
) -> DependencyDraft? {
  match (draft, kind) {
    (Some(draft), PendingDependencies(task_id~)) if draft.task_id == task_id =>
      None
    _ => draft
  }
}

///|
fn missing_uuid_notice(model : Model) -> Model {
  {
    ..model,
    notice: Some(
      notice(
        Error,
        "This browser cannot generate the identifiers required to submit changes.",
      ),
    ),
  }
}

///|
/// Queue the drafted attempt. The live ID validation is quiet; the view
/// keeps the control disabled in every disallowed state.
fn submit_attempt_queue(
  model : Model,
  emit : @rabbita.Emit[Msg],
  env : Env,
) -> (Model, @rabbita.Cmd) {
  guard model.attempt_draft is Some(draft) &&
    attempt_draft_editable(model, draft) else {
    return (model, @rabbita.none)
  }
  if !queue_attempt_id_valid(model.replica, draft.attempt_id) {
    return (model, @rabbita.none)
  }
  guard (env.uuid)() is Some(uuid) && uuid != "" else {
    return (missing_uuid_notice(model), @rabbita.none)
  }
  let attempt_id = draft.attempt_id.trim().to_owned()
  dispatch_command(
    model,
    queue_attempt_command(uuid, model.replica.revision(), draft),
    PendingAttemptQueue(task_id=draft.task_id, attempt_id~),
    emit,
  )
}

///|
/// Start one attempt whose authoritative status is queued.
fn submit_attempt_start(
  model : Model,
  attempt_id : String,
  emit : @rabbita.Emit[Msg],
  env : Env,
) -> (Model, @rabbita.Cmd) {
  if !attempt_controls_allowed(model) {
    return (model, @rabbita.none)
  }
  guard attempt_by_id(model.replica, attempt_id) is Some(attempt) &&
    model.selected_task == Some(attempt.task_id) &&
    task_by_id(model.replica, attempt.task_id) is Some(_) &&
    attempt_startable(attempt.status) else {
    return (model, @rabbita.none)
  }
  guard (env.uuid)() is Some(uuid) && uuid != "" else {
    return (missing_uuid_notice(model), @rabbita.none)
  }
  dispatch_command(
    model,
    start_attempt_command(uuid, model.replica.revision(), attempt_id),
    PendingAttemptStart(attempt_id~),
    emit,
  )
}

///|
/// Finish one running attempt with the explicitly selected terminal
/// outcome; the durable server stays authoritative over every transition.
fn submit_attempt_finish(
  model : Model,
  emit : @rabbita.Emit[Msg],
  env : Env,
) -> (Model, @rabbita.Cmd) {
  guard model.finish_draft is Some(draft) &&
    finish_submit_allowed(model, draft) &&
    draft.outcome is Some(outcome) else {
    return (model, @rabbita.none)
  }
  guard (env.uuid)() is Some(uuid) && uuid != "" else {
    return (missing_uuid_notice(model), @rabbita.none)
  }
  dispatch_command(
    model,
    finish_attempt_command(
      uuid,
      model.replica.revision(),
      draft.attempt_id,
      outcome,
    ),
    PendingAttemptFinish(attempt_id=draft.attempt_id),
    emit,
  )
}
