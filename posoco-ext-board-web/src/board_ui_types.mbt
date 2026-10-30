///|
priv enum TicketAnswer {
  TicketText(String)
  TicketConfirm(Bool)
  TicketSelect(Int32)
}

///|
/// Correlation record for the single in-flight mutation. It retains the
/// command id, the mutation kind and the expected revision; the command
/// payload itself is never stored, so a reconnect cannot resend it.
priv struct PendingCommand {
  command_id : String
  kind : PendingKind
  revision : Int64
} derive(Eq)

///|
priv enum PendingKind {
  PendingCreate
  PendingEdit(task_id~ : String)
  PendingDependencies(task_id~ : String)
  PendingMove(task_id~ : String, to~ : @client.ClientBoardStage)
  PendingAttemptQueue(task_id~ : String, attempt_id~ : String)
  PendingAttemptStart(attempt_id~ : String)
  PendingAttemptFinish(attempt_id~ : String)
  PendingReview(attempt_id~ : String)
} derive(Eq)

///|
/// Pure local draft. Opening the editor and typing never touches the
/// authoritative replica and never sends anything.
priv struct Editor {
  mode : EditorMode
  title : String
  description : String
  user_story : String
  implementation_suggestions : String
  priority : @client.ClientBoardPriority
  definition_of_done : String
} derive(Eq)

///|
/// Local queue draft with an independently generated attempt identity.
/// Opening it sends nothing; submit generates a separate command UUID.
priv struct AttemptDraft {
  task_id : String
  attempt_id : String
  kind : @client.ClientAttemptKind
} derive(Eq)

///|
priv struct FinishDraft {
  task_id : String
  attempt_id : String
  outcome : @client.ClientAttemptOutcome?
} derive(Eq)

///|
/// Local review draft holding only the target attempt's identity. The
/// decision starts explicitly absent: submission is impossible until the
/// user picks Approved or Changes requested, and opening it sends nothing.
priv struct ReviewDraft {
  task_id : String
  attempt_id : String
  decision : @client.ClientRecordableReviewDecision?
} derive(Eq)

///|
/// Local Request changes draft: the reviewed ticket plus the reviewer's note.
/// Opening it sends nothing and the decision is never recorded through the
/// attempt; submission is a `board.ticket.request_changes` command and stays
/// impossible while the note is blank.
priv struct RequestChangesDraft {
  task_id : String
  feedback : String
} derive(Eq)

///|
priv enum EditorMode {
  CreateMode
  EditMode(task_id~ : String)
} derive(Eq)

///|
priv enum NoticeSeverity {
  Warning
  Error
  Success
} derive(Eq)

///|
/// Notices carry mapped safe text only; wire codes and protocol details are
/// resolved to stable human phrasing before they reach this record. An
/// action offers one follow-up intent (today: undoing a move); it is data,
/// not a closure, so the notice stays comparable.
priv struct Notice {
  severity : NoticeSeverity
  text : String
  action : NoticeAction?
} derive(Eq)

///|
/// One follow-up action attached to a notice. `move_to` names the stage the
/// board should move the task back to when the action fires.
priv struct NoticeAction {
  label : String
  task_id : String
  move_to : @client.ClientBoardStage
} derive(Eq)

///|
/// The locally projected stage of one in-flight move. The replica stays
/// untouched — the overlay lives one render above it and dies with the
/// pending command, so the authoritative record is never rewritten.
priv struct OptimisticMove {
  task_id : String
  from : @client.ClientBoardStage
  to : @client.ClientBoardStage
} derive(Eq)

///|
/// One irreversible step waiting for confirmation. The intent carries only
/// identities; the command is rebuilt at confirm time from live state.
priv enum ConfirmIntent {
  ConfirmDone(task_id~ : String)
  ConfirmReview
} derive(Eq)

///|
/// The confirmation states the consequence at the moment of action instead
/// of asking a generic "are you sure".
fn ConfirmIntent::title(self : ConfirmIntent) -> String {
  match self {
    ConfirmDone(_) => "Mark this task done?"
    ConfirmReview => "Record this review decision?"
  }
}

///|
fn ConfirmIntent::body(self : ConfirmIntent) -> String {
  match self {
    ConfirmDone(_) =>
      "Done is the end of the pipeline. The task leaves the flow lanes and moves to the archive."
    ConfirmReview =>
      "A recorded decision is final: it cannot be changed or cleared, and it does not move the task by itself."
  }
}

///|
fn ConfirmIntent::action(self : ConfirmIntent) -> String {
  match self {
    ConfirmDone(_) => "Mark done"
    ConfirmReview => "Record decision"
  }
}

