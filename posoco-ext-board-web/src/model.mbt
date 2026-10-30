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
  team_tab : String
  sm_draft : String
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
  TicketAnsweredAsPo(String, String)
  RolePlanToggled(String, String, Bool)
  TicketPoRequested(String)
  TicketShape(String)
  TicketRun(String)
  TicketRetry(String)
  TicketResume(String)
  TicketSetModel(String, ModelChoice?)
  TicketRunReady
  SmDraftChanged(String)
  SmConsult(String)
  TicketResultDismissed(String)
  TicketResult(Bool, String?, TicketState?)
  ArchiveOpened
  ArchiveClosed
  LiveOpened
  LiveClosed
  TeamOpened
  TeamClosed
  TeamTabChanged(String)
  TeamNameChanged(String, String)
  TeamMcpEnabledChanged(String, Bool)
  TeamMcpAllChanged(String, Bool)
  TeamMcpServerToggled(String, String)
  TeamMcpToolsRestricted(String, Bool)
  TeamMcpToolToggled(String, String)
  TeamSkillsEnabledChanged(String, Bool)
  TeamSkillsAllChanged(String, Bool)
  TeamSkillToggled(String, String)
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
    team_tab: "po",
    sm_draft: "",
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
