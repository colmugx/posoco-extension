///|
/// Environment injected by the browser entry: the Board socket URL plus the
/// UUID seam. Pure tests substitute their own `uuid` provider; the browser
/// provider uses `crypto.randomUUID` and returns `None` when the platform
/// cannot supply one, so callers never fall back to weak identifiers.
priv struct Env {
  url : String
  uuid : () -> String?
}

///|
/// A mutation may only enter the wire while the replica is authoritative and
/// no command is in flight: online, holding a snapshot, with no pending
/// command. The revision stamped onto the command is read live at submit.
fn mutations_allowed(model : Model) -> Bool {
  model.connection is Online &&
  model.replica.has_snapshot() &&
  model.pending is None
}

///|
/// Look up one task from the authoritative replica. Absence of a snapshot
/// means the board is unknown, not empty, so lookups fail closed.
fn task_by_id(
  replica : @client.BoardReplica,
  task_id : String,
) -> @client.ClientBoardTask? {
  if !replica.has_snapshot() {
    return None
  }
  replica.tasks().filter(task => task.id == task_id).get(0)
}

///|
/// A fresh create draft starts blank with the board's default priority.
fn Editor::create() -> Editor {
  {
    mode: CreateMode,
    title: "",
    description: "",
    priority: Normal,
    definition_of_done: "",
  }
}

///|
/// Prefill an edit draft from the authoritative record. Definition-of-done
/// entries rejoin as editor lines so round-trips stay lossless.
fn Editor::from_task(
  mode : EditorMode,
  task : @client.ClientBoardTask,
) -> Editor {
  {
    mode,
    title: task.title,
    description: task.description,
    priority: task.priority,
    definition_of_done: definition_of_done_text(task.definition_of_done),
  }
}

///|
/// Build the create command from a draft and an injected identifier. IDs are
/// `cmd-`/`task-` prefixed UUIDs; dependencies are not part of the v1 web
/// editor and stay empty. Priority spelling uses the client's `to_wire`.
fn create_command(
  uuid : String,
  revision : Int64,
  editor : Editor,
) -> @protocol.BoardClientCommand {
  @client.create_task_command(
    "cmd-" + uuid,
    revision,
    id="task-" + uuid,
    title=editor.title.trim().to_owned(),
    description=editor.description,
    priority=editor.priority,
    definition_of_done=definition_of_done_lines(editor.definition_of_done),
    dependencies=[],
  )
}

///|
/// Build the update command for an edit draft. Every draft field is sent
/// explicitly; the durable server decides semantics.
fn update_command(
  uuid : String,
  revision : Int64,
  task_id : String,
  editor : Editor,
) -> @protocol.BoardClientCommand {
  @client.update_task_command(
    "cmd-" + uuid,
    revision,
    id=task_id,
    title=editor.title.trim().to_owned(),
    description=editor.description,
    priority=editor.priority,
    definition_of_done=definition_of_done_lines(editor.definition_of_done),
  )
}

///|
/// Build the move command for one card; the stage rides the client enum so
/// no wire spelling is duplicated here.
fn move_command(
  uuid : String,
  revision : Int64,
  task_id : String,
  to : @client.ClientBoardStage,
) -> @protocol.BoardClientCommand {
  @client.move_task_command("cmd-" + uuid, revision, id=task_id, to~)
}

///|
/// Keep the draft's attempt identity separate from this submission's command UUID.
fn queue_attempt_command(
  uuid : String,
  revision : Int64,
  draft : AttemptDraft,
) -> @protocol.BoardClientCommand {
  @client.queue_attempt_command(
    "cmd-" + uuid,
    revision,
    id=draft.attempt_id.trim().to_owned(),
    task_id=draft.task_id,
    kind=draft.kind,
  )
}

///|
/// Build the review command from the ID-only draft. The decision rides the
/// recordable client enum, so `pending` can never be encoded; the durable
/// server decides whether the attempt may still receive it.
fn review_command(
  uuid : String,
  revision : Int64,
  attempt_id : String,
  decision : @client.ClientRecordableReviewDecision,
) -> @protocol.BoardClientCommand {
  @client.record_review_command(
    "cmd-" + uuid,
    revision,
    id=attempt_id,
    decision~,
  )
}

///|
fn start_attempt_command(
  uuid : String,
  revision : Int64,
  attempt_id : String,
) -> @protocol.BoardClientCommand {
  @client.start_attempt_command("cmd-" + uuid, revision, id=attempt_id)
}

///|
/// The terminal outcome rides the client enum from the explicit draft
/// selection; nothing here defaults or infers it.
fn finish_attempt_command(
  uuid : String,
  revision : Int64,
  attempt_id : String,
  outcome : @client.ClientAttemptOutcome,
) -> @protocol.BoardClientCommand {
  @client.finish_attempt_command(
    "cmd-" + uuid,
    revision,
    id=attempt_id,
    outcome~,
  )
}

///|
/// Resolve a select value back to an attempt kind by comparing against the
/// centralized `to_wire` spellings; unknown values keep the current draft.
fn attempt_kind_from_wire(value : String) -> @client.ClientAttemptKind? {
  attempt_kinds().filter(kind => kind.to_wire() == value).get(0)
}

///|
/// Resolve a select value back to a terminal outcome; unknown values keep
/// the current selection.
fn attempt_outcome_from_wire(value : String) -> @client.ClientAttemptOutcome? {
  attempt_outcomes().filter(outcome => outcome.to_wire() == value).get(0)
}

///|
/// Resolve a select value back to a recordable review decision by comparing
/// against the centralized `to_wire` spellings; unknown values keep the
/// current draft and an empty value clears it back to no decision.
fn review_decision_from_wire(
  value : String,
) -> @client.ClientRecordableReviewDecision? {
  review_decisions().filter(decision => decision.to_wire() == value).get(0)
}

///|
/// Resolve a select value back to a priority by comparing against the
/// centralized `to_wire` spellings; unknown values keep the current draft.
fn priority_from_wire(value : String) -> @client.ClientBoardPriority? {
  priorities().filter(priority => priority.to_wire() == value).get(0)
}

///|
fn notice(severity : NoticeSeverity, text : String) -> Notice {
  { severity, text, }
}

///|
/// Stable rejection codes map to fixed phrasing. Unknown codes collapse to
/// one generic sentence: notices never echo store, protocol or debug detail.
fn rejection_text(error : String?) -> String {
  match error {
    Some("task_not_found") => "That task no longer exists on the board."
    Some("invalid_transition") =>
      "The board does not allow this change from the task's current stage."
    Some("invalid_input") | Some("invalid_arguments") =>
      "The board rejected this change as invalid."
    Some("attempt_not_found") => "That attempt no longer exists."
    Some("invalid_attempt_transition") =>
      "The board does not allow this change from the attempt's current status."
    Some("invalid_review_transition") =>
      "The board does not allow this review decision from the attempt's current state."
    Some("duplicate_attempt") => "An attempt with that ID already exists."
    Some("dependency_not_found") =>
      "A selected dependency no longer exists. Remove it or reload the latest dependencies."
    Some("self_dependency") => "A task cannot depend on itself."
    Some("duplicate_dependency") => "Select each dependency only once."
    Some("dependency_cycle") =>
      "These dependencies would create a cycle. Choose a different set."
    Some("board_initializing") | Some("board_unavailable") =>
      "The board is not ready to accept changes yet."
    Some("board_timeout") =>
      "The board did not respond in time; the change was not confirmed."
    Some("persistence_failed") =>
      "The board could not save this change. Nothing was retried."
    Some(_) => "The board rejected this change."
    None => "The board rejected this change."
  }
}

///|
fn accepted_text(kind : PendingKind) -> String {
  match kind {
    PendingCreate => "Task create saved."
    PendingEdit(..) => "Task update saved."
    PendingDependencies(..) => "Task dependencies saved."
    PendingMove(..) => "Task move saved."
    PendingAttemptQueue(..) => "Attempt queued."
    PendingAttemptStart(..) => "Attempt start saved."
    PendingAttemptFinish(..) => "Attempt finish saved."
    PendingReview(..) => "Review decision saved."
  }
}

///|
fn notice_class(severity : NoticeSeverity) -> String {
  match severity {
    Warning => "notice-warning"
    Error => "notice-error"
    Success => "notice-success"
  }
}

///|
/// An accepted correlated command closes only the editor that produced it.
fn close_matching_editor(editor : Editor?, kind : PendingKind) -> Editor? {
  match (editor, kind) {
    (Some(editor), PendingCreate) if editor.mode is CreateMode => None
    (Some(editor), PendingEdit(task_id=pending_id)) =>
      match editor.mode {
        EditMode(task_id=editing_id) if editing_id == pending_id => None
        _ => Some(editor)
      }
    _ => editor
  }
}

///|
/// An accepted correlated queue closes only the draft that produced it;
/// start and finish leave queue drafts untouched.
fn settle_attempt_draft(
  draft : AttemptDraft?,
  kind : PendingKind,
) -> AttemptDraft? {
  match (draft, kind) {
    (Some(draft), PendingAttemptQueue(task_id~, attempt_id~)) if draft.task_id ==
      task_id &&
      draft.attempt_id.trim().to_owned() == attempt_id => None
    _ => draft
  }
}

///|
fn settle_finish_draft(
  draft : FinishDraft?,
  kind : PendingKind,
) -> FinishDraft? {
  match (draft, kind) {
    (Some(draft), PendingAttemptFinish(attempt_id~)) if draft.attempt_id ==
      attempt_id => None
    _ => draft
  }
}

///|
/// An accepted correlated review closes only the draft that produced it;
/// every other pending kind leaves the review draft untouched.
fn settle_review_draft(
  draft : ReviewDraft?,
  kind : PendingKind,
) -> ReviewDraft? {
  match (draft, kind) {
    (Some(draft), PendingReview(attempt_id~)) if draft.attempt_id == attempt_id =>
      None
    _ => draft
  }
}

///|
/// After an authoritative frame an edit draft whose task vanished from the
/// snapshot closes. A draft is never closed just because reconciliation
/// emptied the baseline: without a snapshot the board is unknown, and the
/// draft survives until authoritative state returns.
fn close_missing_edit_target(model : Model) -> Model {
  match model.editor {
    Some(editor) =>
      match editor.mode {
        EditMode(task_id~) =>
          if model.replica.has_snapshot() &&
            task_by_id(model.replica, task_id) is None {
            {
              ..model,
              editor: None,
              notice: Some(
                notice(Error, "That task is no longer on the board."),
              ),
            }
          } else {
            model
          }
        _ => model
      }
    None => model
  }
}
