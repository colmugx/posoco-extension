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
    Some("invalid_input") => "The board rejected this change as invalid."
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
