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
} derive(Eq)

///|
/// Pure local draft. Opening the editor and typing never touches the
/// authoritative replica and never sends anything.
priv struct Editor {
  mode : EditorMode
  title : String
  description : String
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
/// resolved to stable human phrasing before they reach this record.
priv struct Notice {
  severity : NoticeSeverity
  text : String
} derive(Eq)

///|
priv struct Model {
  replica : @client.BoardReplica
  connection : ConnectionState
  retry_attempt : Int
  generation : Int
  retry_pending : Bool
  last_status : String
  pending : PendingCommand?
  editor : Editor?
  notice : Notice?
  selected_task : String?
  dependency_editor : DependencyDraft?
  attempt_draft : AttemptDraft?
  finish_draft : FinishDraft?
} derive(Eq)

///|
priv enum Msg {
  SocketEvent(Int, @websocket.Event)
  TransportFailed(Int)
  Retry(Int)
  SendFailed(Int, String)
  CreateOpened
  EditOpened(String)
  EditorCancelled
  TitleChanged(String)
  DescriptionChanged(String)
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
  DependencyDraftReturned
  AttemptQueueOpened
  AttemptQueueCancelled
  AttemptDraftReturned
  AttemptFinishOpened(String)
  AttemptFinishCancelled
  AttemptKindChanged(String)
  AttemptQueueSubmitted
  AttemptStartRequested(String)
  AttemptOutcomeChanged(String)
  AttemptFinishSubmitted
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
    retry_attempt: 0,
    generation: 0,
    retry_pending: false,
    last_status: if available {
      "Waiting for Board snapshot"
    } else {
      "Open this client from a Board host with an instance token"
    },
    pending: None,
    editor: None,
    notice: None,
    selected_task: None,
    dependency_editor: None,
    attempt_draft: None,
    finish_draft: None,
  }
}

///|
/// Bounded reconnect progression. A committed snapshot resets the attempt.
pub fn retry_delay(attempt : Int) -> Int {
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
