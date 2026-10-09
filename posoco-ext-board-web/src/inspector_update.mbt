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
      if !mutations_allowed(model) ||
        model.editor is Some(_) ||
        model.dependency_editor is Some(_) {
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
    _ => (model, @rabbita.none)
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
