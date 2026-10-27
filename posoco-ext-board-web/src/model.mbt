///|
pub(all) enum ConnectionState {
  Connecting
  Online
  Reconnecting
  Offline
  ProtocolError(String)
} derive(Eq)

///|
pub extend ConnectionState with Eq::{equal, not_equal}

///|
/// Which authoritative baseline the replica holds, so operational status can
/// distinguish a first snapshot, a reconnect on a retained baseline and an
/// invalidated baseline that needs a fresh snapshot.
priv enum BaselineState {
  AwaitingFirst
  Confirmed
  Retained
  Invalidated
} derive(Eq)

///|
/// Pure local view filter. It never sends anything and never touches the
/// replica, the selection or any draft.
priv struct TaskFilter {
  query : String
  priority : @client.ClientBoardPriority?
  stage : @client.ClientBoardStage?
} derive(Eq)

///|
priv struct TicketQuestion {
  id : String
  task_id : String
  question : String
  kind : String
  options : Array[String]
  asked_at : Int64
  asked_by : String
  audience : String
  status : String
} derive(Eq)

///|
priv struct TicketActivity {
  at_ms : Int64
  kind : String
  text : String
} derive(Eq)

///|
priv struct TicketRun {
  task_id : String
  session_id : String
  phase : String
  role : String
  status : String
  error : String?
  result : String?
  steps : Int32
  current_tool : String?
  preview : String
  reasoning : String
  activities : Array[TicketActivity]
} derive(Eq)

///|
/// One non-blocking worker update from `ticket_state.progress`. It is
/// information only: it carries no question, no answer and no stage, so the
/// inbox renders it and never offers a reply, a resolve or a move.
priv struct TicketProgress {
  task_id : String
  /// Bounded tone: `normal`, `milestone`, `attention` or `blocked`. Anything
  /// outside that set reads as `normal` rather than inventing a tone the
  /// stylesheet cannot colour.
  kind : String
  message : String
  at_ms : Int64
} derive(Eq)

///|
/// One selectable model as the host advertises it in `ticket_state`. The
/// catalog is runtime state: it is never persisted with the ticket journal,
/// and every field except the stable slot id may be missing.
priv struct ModelOption {
  id : String
  label : String
  provider : String
  model : String
  efforts : Array[String]
  default_effort : String?
  context_window : Int64?
  capabilities : Array[String]
} derive(Eq)

///|
/// The host's per-ticket model catalog. An absent catalog and
/// `selectable=false` both mean the picker stays read-only, so a pinned
/// ticket keeps the model it already has instead of silently falling back.
priv struct ModelCatalog {
  selectable : Bool
  kind : String
  models : Array[ModelOption]
} derive(Eq)

///|
fn ModelCatalog::unavailable() -> ModelCatalog {
  { selectable: false, kind: "", models: [], }
}

///|
fn ModelCatalog::find(self : ModelCatalog, slot : String) -> ModelOption? {
  self.models.filter(model => model.id == slot).get(0)
}

///|
/// One ticket's model choice: the stable slot id plus an optional effort.
/// `None` in `Msg::TicketSetModel` (and on the wire) means inherit the
/// current Cetas model and keep following `/model`.
priv struct ModelChoice {
  slot : String
  effort : String?
}

///|
/// Host runtime facts for the Live popover. Quota is optional: a manager that
/// does not expose it renders "not exposed", never a made-up number.
priv struct TicketLiveInfo {
  manager : String
  active_model : String
  active_effort : String?
  provider : String
  context_window : Int64?
  model_count : Int32
  quota_lines : Array[String]
} derive(Eq)

///|
/// Lightweight names shown in prompts and on the Board. Defaults are used
/// when the host frame has no team field.
priv struct TeamNames {
  refiner : String
  rd : String
  set : String
  te : String
} derive(Eq)

///|
fn TeamNames::defaults() -> TeamNames {
  { refiner: "Agile Coach", rd: "RD", set: "SET", te: "TE", }
}

///|
priv struct WorkProfile {
  id : String
  label : String
} derive(Eq)

///|
fn WorkProfile::software() -> WorkProfile {
  { id: "software", label: "Software" }
}

///|
fn work_profiles() -> Array[WorkProfile] {
  [
    WorkProfile::software(),
    { id: "document", label: "Document" },
    { id: "analysis", label: "Analysis" },
  ]
}

///|
priv struct TicketState {
  project : String
  team : TeamNames?
  profile : WorkProfile
  questions : Array[TicketQuestion]
  runs : Array[TicketRun]
  /// Non-blocking worker updates. They are shown in the inbox and never own a
  /// question, an answer or a stage move of their own.
  progress : Array[TicketProgress]
  live : TicketLiveInfo?
  /// Absent when this frame did not carry a catalog; the previous catalog is
  /// retained so a `ticket_result` cannot blank the picker mid-edit.
  model_selection : ModelCatalog?
} derive(Eq)

///|
fn TicketState::empty() -> TicketState {
  {
    project: "",
    team: None,
    profile: WorkProfile::software(),
    questions: [],
    runs: [],
    progress: [],
    live: None,
    model_selection: None,
  }
}

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

///|
priv struct Model {
  replica : @client.BoardReplica
  connection : ConnectionState
  can_connect : Bool
  baseline : BaselineState
  retry_attempt : Int32
  generation : Int32
  retry_pending : Bool
  last_status : String
  pending : PendingCommand?
  /// The locally projected stage of one in-flight move; the replica itself
  /// is never rewritten ahead of the authoritative stream.
  optimistic : OptimisticMove?
  /// True after a revision conflict or uncertain durability: the retained
  /// baseline is shown under a stale veil while the reconnect replays the
  /// missed frames. Cleared by the next applied frame.
  stale : Bool
  editor : Editor?
  notice : Notice?
  selected_task : String?
  ticket_activity_task : String?
  dependency_editor : DependencyDraft?
  attempt_draft : AttemptDraft?
  finish_draft : FinishDraft?
  review_draft : ReviewDraft?
  request_changes_draft : RequestChangesDraft?
  task_filter : TaskFilter
  tickets : TicketState
  ticket_available : Bool
  ticket_drawer : Bool
  ticket_drafts : Map[String, String]
  ticket_sending : Bool
  /// Identities of the worker updates the inbox has already shown. It only
  /// tracks what the user looked at; the authoritative list stays in
  /// `tickets.progress`.
  ticket_seen_updates : Map[String, Bool]
  confirm : ConfirmIntent?
  archive_open : Bool
  live_open : Bool
  team_open : Bool
  team_draft : TeamNames
  team_profile_draft : WorkProfile
} derive(Eq)

///|
priv enum Msg {
  SocketEvent(Int32, @websocket.Event)
  TransportFailed(Int32)
  Retry(Int32)
  ConnectionStable(Int32)
  ManualReconnect
  SendFailed(Int32, String)
  CreateOpened
  EditOpened(String)
  EditorCancelled
  TitleChanged(String)
  DescriptionChanged(String)
  UserStoryChanged(String)
  ImplementationSuggestionsChanged(String)
  PriorityChanged(String)
  DefinitionOfDoneChanged(String)
  SubmitRequested
  MoveRequested(String, @client.ClientBoardStage)
  TaskSelected(String)
  InspectorClosed
  DependenciesOpened
  DependencyToggled(String, Bool)
  DependencySelectionChanged(String)
  DependenciesCleared
  DependenciesRefreshed
  DependenciesCancelled
  DependenciesSubmitted
  AttemptQueueOpened
  AttemptQueueCancelled
  AttemptFinishOpened(String)
  AttemptFinishCancelled
  AttemptKindChanged(String)
  AttemptQueueSubmitted
  AttemptStartRequested(String)
  AttemptOutcomeChanged(String)
  AttemptFinishSubmitted
  RequestChangesOpened(String)
  RequestChangesFeedbackChanged(String)
  RequestChangesSubmitted
  RequestChangesCancelled
  FilterQueryChanged(String)
  FilterPriorityChanged(String)
  FilterStageChanged(String)
  FiltersCleared
  TicketDrawerOpened
  TicketDrawerClosed
  TicketActivityOpened(String)
  TicketActivityClosed
  TicketUpdatesDismissed
  TicketDraftChanged(String, String)
  TicketAnswered(String, TicketAnswer)
  TicketAnsweredAsRefiner(String, String)
  TicketRefinerRequested(String)
  TicketShape(String)
  TicketRun(String)
  TicketRetry(String)
  TicketResume(String)
  TicketSetModel(String, ModelChoice?)
  TicketRunReady
  TicketResultDismissed(String)
  TicketResult(Bool, String?, TicketState?)
  ArchiveOpened
  ArchiveClosed
  LiveOpened
  LiveClosed
  TeamOpened
  TeamClosed
  TeamNameChanged(String, String)
  TeamProfileChanged(String)
  TeamSaved
  DoneRequested(String)
  NoticeActionInvoked
  KeyboardMove(Int32)
  ReviewDecide(String, String)
  ConfirmAccepted
  ConfirmDismissed
  NoticeDismissed
}

///|
fn TaskFilter::none() -> TaskFilter {
  { query: "", priority: None, stage: None, }
}

///|
fn Model::empty(available : Bool) -> Model {
  {
    replica: @client.BoardReplica::empty(),
    connection: if available {
      Connecting
    } else {
      Offline
    },
    can_connect: available,
    baseline: AwaitingFirst,
    retry_attempt: 0,
    generation: 0,
    retry_pending: false,
    last_status: if available {
      "Waiting for Board snapshot"
    } else {
      "Open this client from a Board host with an instance token"
    },
    pending: None,
    optimistic: None,
    stale: false,
    editor: None,
    notice: None,
    selected_task: None,
    ticket_activity_task: None,
    dependency_editor: None,
    attempt_draft: None,
    finish_draft: None,
    review_draft: None,
    request_changes_draft: None,
    task_filter: TaskFilter::none(),
    tickets: TicketState::empty(),
    ticket_available: false,
    ticket_drawer: false,
    ticket_drafts: Map([]),
    ticket_sending: false,
    ticket_seen_updates: Map([]),
    confirm: None,
    archive_open: false,
    live_open: false,
    team_open: false,
    team_draft: TeamNames::defaults(),
    team_profile_draft: WorkProfile::software(),
  }
}

///|
/// Bounded reconnect progression. A committed snapshot resets the attempt.
pub fn retry_delay(attempt : Int32) -> Int32 {
  match attempt {
    n if n <= 0 => 250
    1 => 500
    2 => 1000
    3 => 2000
    4 => 4000
    5 => 8000
    _ => 10000
  }
}

///|
pub fn connection_label(state : ConnectionState) -> String {
  match state {
    Connecting => "Connecting"
    Online => "Online"
    Reconnecting => "Reconnecting"
    Offline => "Offline"
    ProtocolError(_) => "Protocol error"
  }
}
