// delegation.mbt — the thin `delegate_task` seam (cetas-lody plan Phase 5):
// provider-neutral intent in, lody MCP tool calls out. The neutral intent /
// call / phase types live in colmugx/posoco-kit-delegation (shared with the
// paseo kit) and are re-exported here; this file keeps the lody realization
// (`lody_session_create` / `lody_session_chat`) and the mapping from the
// contract's two deliberately disjoint status vocabularies onto the unified
// phase view.

///|
/// Provider-neutral delegation types (canonical home:
/// colmugx/posoco-kit-delegation), re-exported so the kit-lody public face
/// keeps the `DelegationIntent` / `DelegationCall` / `DelegationPhase` names.
pub using @delegation {
  type DelegationIntent,
  type DelegationCall,
  type DelegationPhase,
}

///|
/// `lody_session_create` — the lody MCP tool that opens a delegated session.
pub const LODY_MCP_SESSION_CREATE : String = "lody_session_create"

///|
/// `lody_session_chat` — the lody MCP tool that sends one prompt to a
/// delegated session.
pub const LODY_MCP_SESSION_CHAT : String = "lody_session_chat"

///|
/// Map an intent onto `lody_session_create`. Lody sessions are named by the
/// host: `task_id` is caller-chosen and threaded into
/// `_meta.lody.task.taskId`; the intent's `task` surfaces as `objective`
/// and its optional `cwd` is forwarded. The argument key names are a local
/// proposal: the lody MCP tool schemas are not part of acp-extension-core
/// — awaiting on-wire verification at the cetas-acp dispatch point.
pub fn lody_create_call(
  intent : DelegationIntent,
  task_id~ : String,
) -> DelegationCall {
  let pairs : Array[(String, Json)] = [
    ("taskId", Json::string(task_id)),
    ("objective", Json::string(intent.task)),
  ]
  match intent.cwd {
    Some(dir) => pairs.push(("cwd", Json::string(dir)))
    None => ()
  }
  DelegationCall::{
    tool: LODY_MCP_SESSION_CREATE,
    arguments: Json::object(Map::from_array(pairs)),
  }
}

///|
/// Map the intent's instruction onto `lody_session_chat` for the lody
/// session created from this intent. The full `prompt` is used when
/// present, falling back to the one-line `task`. Argument key names as
/// above — awaiting on-wire verification.
pub fn lody_chat_call(
  intent : DelegationIntent,
  lody_session_id~ : String,
) -> DelegationCall {
  let instruction = match intent.prompt {
    Some(prompt) => prompt
    None => intent.task
  }
  DelegationCall::{
    tool: LODY_MCP_SESSION_CHAT,
    arguments: Json::object(
      Map::from_array([
        ("sessionId", Json::string(lody_session_id)),
        ("prompt", Json::string(instruction)),
      ]),
    ),
  }
}

///|
/// Task-track mapping: pending → Queued, in_progress → Running,
/// completed → Succeeded, failed → Failed.
pub fn phase_of_task_status(status : @lody.LodyTaskStatus) -> DelegationPhase {
  match status {
    @lody.LodyTaskStatus::Pending => Queued
    @lody.LodyTaskStatus::InProgress => Running
    @lody.LodyTaskStatus::Completed => Succeeded
    @lody.LodyTaskStatus::Failed => Failed
  }
}

///|
/// Subagent-track mapping: running → Running, completed → Succeeded,
/// failed / timed_out / killed → Failed (terminal failures), lost → Lost
/// (the result can no longer be observed).
pub fn phase_of_subagent_status(
  status : @lody.LodySubagentStatus,
) -> DelegationPhase {
  match status {
    @lody.LodySubagentStatus::Running => Running
    @lody.LodySubagentStatus::Completed => Succeeded
    @lody.LodySubagentStatus::Failed => Failed
    @lody.LodySubagentStatus::TimedOut => Failed
    @lody.LodySubagentStatus::Killed => Failed
    @lody.LodySubagentStatus::Lost => Lost
  }
}

///|
/// Phase carried by a decoded session meta envelope: the task track when
/// `_meta.lody.task` is present, `None` when the envelope has no task.
pub fn phase_of_session_meta(meta : @lody.LodySessionMeta) -> DelegationPhase? {
  match meta.task {
    Some(task) => Some(phase_of_task_status(task.status))
    None => None
  }
}

///|
/// Read the task-track phase straight off the wire. Accepts either the whole
/// message `_meta` object (its `lody` sub-object is read) or the `lody`
/// object itself; returns `Ok(None)` when no task envelope is present.
pub fn parse_task_phase(meta : Json) -> Result[DelegationPhase?, String] {
  guard meta is Json::Object(fields) else {
    return Err("lody: delegation status must be a JSON object")
  }
  let envelope : Json = match fields.get("lody") {
    Some(inner) =>
      match inner {
        Json::Object(_) => inner
        _ => meta
      }
    None => meta
  }
  match @lody.LodySessionMeta::from_json(envelope) {
    Ok(session_meta) => Ok(phase_of_session_meta(session_meta))
    Err(message) => Err(message)
  }
}

///|
/// Phase of one `_lody/subagents/list` row (subagent track).
pub fn parse_subagent_phase(row : Json) -> Result[DelegationPhase, String] {
  match @lody.LodySubagentTask::from_json(row) {
    Ok(task) => Ok(phase_of_subagent_status(task.status))
    Err(message) => Err(message)
  }
}
