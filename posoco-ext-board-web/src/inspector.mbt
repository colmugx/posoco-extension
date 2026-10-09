///|
priv struct DependencyDraft {
  task_id : String
  base_dependencies : Array[String]
  dependencies : Array[String]
} derive(Eq)

///|
fn DependencyDraft::from_task(
  task : @client.ClientBoardTask,
) -> DependencyDraft {
  {
    task_id: task.id,
    base_dependencies: task.dependencies.copy(),
    dependencies: task.dependencies.copy(),
  }
}

///|
fn inspector_task(model : Model) -> @client.ClientBoardTask? {
  match model.selected_task {
    Some(id) => task_by_id(model.replica, id)
    None => None
  }
}

///|
fn inspector_attempts(model : Model) -> Array[@client.ClientAttempt] {
  guard inspector_task(model) is Some(task) else { return [] }
  model.replica.attempts().filter(attempt => attempt.task_id == task.id)
}

///|
fn dependency_candidates(
  model : Model,
  task_id : String,
) -> Array[@client.ClientBoardTask] {
  if !model.replica.has_snapshot() {
    return []
  }
  model.replica.tasks().filter(task => task.id != task_id)
}

///|
fn dependency_title(model : Model, id : String) -> String {
  match task_by_id(model.replica, id) {
    Some(task) => task.title
    None => "Unavailable task"
  }
}

///|
fn dependencies_equal(left : Array[String], right : Array[String]) -> Bool {
  left.length() == right.length() && left.all(id => right.contains(id))
}

///|
/// Only relationship changes require explicit reload; unrelated revisions do not.
fn dependency_conflict(model : Model, draft : DependencyDraft) -> Bool {
  if model.pending is Some({ kind: PendingDependencies(task_id~), .. }) &&
    task_id == draft.task_id {
    return false
  }
  match task_by_id(model.replica, draft.task_id) {
    Some(task) =>
      !dependencies_equal(draft.base_dependencies, task.dependencies)
    None => false
  }
}

///|
fn dependency_editable(model : Model, draft : DependencyDraft) -> Bool {
  mutations_allowed(model) &&
  model.selected_task == Some(draft.task_id) &&
  task_by_id(model.replica, draft.task_id) is Some(_)
}

///|
fn dependency_save_allowed(model : Model, draft : DependencyDraft) -> Bool {
  dependency_editable(model, draft) && !dependency_conflict(model, draft)
}

///|
fn revalidate_inspector(model : Model) -> Model {
  if !model.replica.has_snapshot() {
    return model
  }
  let selected_missing = model.selected_task is Some(id) &&
    task_by_id(model.replica, id) is None
  let draft_missing = model.dependency_editor is Some(draft) &&
    task_by_id(model.replica, draft.task_id) is None
  if selected_missing || draft_missing {
    {
      ..model,
      selected_task: if selected_missing {
        None
      } else {
        model.selected_task
      },
      dependency_editor: if draft_missing {
        None
      } else {
        model.dependency_editor
      },
      notice: Some(
        notice(
          Warning,
          "The inspected task or dependency draft target no longer exists.",
        ),
      ),
    }
  } else {
    model
  }
}

///|
fn dependency_toggle(model : Model, id : String, checked : Bool) -> Model {
  guard model.dependency_editor is Some(draft) &&
    dependency_editable(model, draft) else {
    return model
  }
  if id == draft.task_id {
    return model
  }
  let dependencies = if checked {
    if draft.dependencies.contains(id) || task_by_id(model.replica, id) is None {
      return model
    }
    [..draft.dependencies, id]
  } else {
    draft.dependencies.filter(value => value != id)
  }
  { ..model, dependency_editor: Some({ ..draft, dependencies, }), }
}

///|
fn dependency_refresh(model : Model) -> Model {
  guard model.dependency_editor is Some(draft) &&
    dependency_editable(model, draft) else {
    return model
  }
  guard task_by_id(model.replica, draft.task_id) is Some(task) else {
    return model
  }
  { ..model, dependency_editor: Some(DependencyDraft::from_task(task)), }
}
