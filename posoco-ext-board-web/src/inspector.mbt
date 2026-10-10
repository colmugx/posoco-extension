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
  let attempts = model.replica
    .attempts()
    .filter(attempt => attempt.task_id == task.id)
  attempts.sort_by((left, right) => {
    let created = left.created_at_ms.compare(right.created_at_ms)
    if created == 0 {
      left.id.compare(right.id)
    } else {
      created
    }
  })
  attempts
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
  let attempt_draft_missing = model.attempt_draft is Some(draft) &&
    task_by_id(model.replica, draft.task_id) is None
  let finish_missing = model.finish_draft is Some(draft) &&
    (
      task_by_id(model.replica, draft.task_id) is None ||
      attempt_by_id(model.replica, draft.attempt_id) is None
    )
  let review_missing = model.review_draft is Some(draft) &&
    (
      task_by_id(model.replica, draft.task_id) is None ||
      attempt_by_id(model.replica, draft.attempt_id) is None
    )
  if selected_missing ||
    draft_missing ||
    attempt_draft_missing ||
    finish_missing ||
    review_missing {
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
      attempt_draft: if attempt_draft_missing {
        None
      } else {
        model.attempt_draft
      },
      finish_draft: if finish_missing {
        None
      } else {
        model.finish_draft
      },
      review_draft: if review_missing {
        None
      } else {
        model.review_draft
      },
      notice: Some(
        notice(Warning, "The inspected task or draft target no longer exists."),
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

///|
fn attempt_by_id(
  replica : @client.BoardReplica,
  attempt_id : String,
) -> @client.ClientAttempt? {
  if !replica.has_snapshot() {
    return None
  }
  replica.attempts().filter(attempt => attempt.id == attempt_id).get(0)
}

///|
/// Attempt draft edits share the mutation gate and the inspected task.
fn attempt_draft_editable(model : Model, draft : AttemptDraft) -> Bool {
  mutations_allowed(model) &&
  model.selected_task == Some(draft.task_id) &&
  task_by_id(model.replica, draft.task_id) is Some(_)
}

///|
/// Live draft validation feeds the view's disabled state; submit re-checks
/// it quietly before building the command.
fn attempt_queue_submit_allowed(model : Model, draft : AttemptDraft) -> Bool {
  attempt_draft_editable(model, draft) &&
  queue_attempt_id_valid(model.replica, draft.attempt_id)
}

///|
/// Manual start/finish/review controls share one disabled state with every
/// other editor: no command in flight and no open editor or draft.
fn draft_open(model : Model) -> Bool {
  model.editor is Some(_) ||
  model.dependency_editor is Some(_) ||
  model.attempt_draft is Some(_) ||
  model.finish_draft is Some(_) ||
  model.review_draft is Some(_)
}

///|
fn attempt_controls_allowed(model : Model) -> Bool {
  mutations_allowed(model) && !draft_open(model)
}

///|
fn finish_draft_editable(model : Model, draft : FinishDraft) -> Bool {
  mutations_allowed(model) &&
  model.selected_task == Some(draft.task_id) &&
  task_by_id(model.replica, draft.task_id) is Some(_) &&
  attempt_by_id(model.replica, draft.attempt_id) is Some(attempt) &&
  attempt.task_id == draft.task_id &&
  attempt_finishable(attempt.status)
}

///|
fn finish_submit_allowed(model : Model, draft : FinishDraft) -> Bool {
  finish_draft_editable(model, draft) && draft.outcome is Some(_)
}

///|
fn finish_review_warning(attempt : @client.ClientAttempt) -> String? {
  if finish_review_pending(attempt) {
    Some(
      "Finishing now will leave this review without a recorded decision. A decision cannot be recorded after the attempt finishes.",
    )
  } else {
    None
  }
}

///|
/// Live review draft validation against the authoritative replica: the
/// inspected task and attempt must still exist and the attempt must remain
/// inside the record window — a Running Review attempt still Pending. An
/// external decision or finish therefore disables submission live.
fn review_draft_editable(model : Model, draft : ReviewDraft) -> Bool {
  mutations_allowed(model) &&
  model.selected_task == Some(draft.task_id) &&
  task_by_id(model.replica, draft.task_id) is Some(_) &&
  attempt_by_id(model.replica, draft.attempt_id) is Some(attempt) &&
  attempt.task_id == draft.task_id &&
  review_recordable(attempt)
}

///|
/// Recording always requires an explicit decision: the placeholder is the
/// only no-decision state and submission stays disabled until one is chosen.
fn review_submit_allowed(model : Model, draft : ReviewDraft) -> Bool {
  review_draft_editable(model, draft) && draft.decision is Some(_)
}
