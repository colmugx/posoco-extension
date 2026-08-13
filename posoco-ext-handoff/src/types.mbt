///|
/// One workspace change captured at handoff time. The probe owns the status
/// vocabulary (for example `modified`, `staged`, `untracked`); the handoff
/// renderer treats it as an opaque factual label.
pub(all) struct WorkspaceChange {
  path : String
  status : String
} derive(Eq, Debug)

///|
/// Deterministic project facts captured by the host. The handoff extension
/// deliberately does not know how Git, a VCS, or another workspace backend
/// obtains these values.
pub(all) struct WorkspaceSnapshot {
  root : String
  branch : String?
  head : String?
  changes : Array[WorkspaceChange]
} derive(Eq, Debug)

///|
/// Semantic work state that is already known by the caller or another
/// deterministic product component. The handoff extension never asks an LLM
/// to infer these fields from conversation history.
///
/// `next_action` is singular by design: a handoff must identify one immediate
/// executable continuation. Later actions belong in `queue`.
pub(all) struct WorkSnapshot {
  objective : String?
  done_when : Array[String]
  constraints : Array[String]
  completed : Array[String]
  current_work : String?
  decisions : Array[String]
  blockers : Array[String]
  next_action : String?
  queue : Array[String]
  notes : Array[String]
  validation_passed : Array[String]
  validation_failed : Array[String]
  validation_not_run : Array[String]
} derive(Eq, Debug)

///|
pub fn WorkSnapshot::empty() -> WorkSnapshot {
  {
    objective: None,
    done_when: [],
    constraints: [],
    completed: [],
    current_work: None,
    decisions: [],
    blockers: [],
    next_action: None,
    queue: [],
    notes: [],
    validation_passed: [],
    validation_failed: [],
    validation_not_run: [],
  }
}

///|
/// A deterministic producer of handoff work facts.
///
/// This is intentionally an extension-local seam rather than a Posoco port:
/// handoff must not inspect or reverse-query the internal state of unrelated
/// ports. Products may adapt their own planner/task/workflow state into this
/// interface explicitly.
pub(open) trait HandoffWorkSource {
  fn handoff_work(Self) -> WorkSnapshot
}

///|
/// Minimal persistence required by the handoff extension. Keeping this seam
/// local avoids coupling HANDOFF.md generation to another extension package or
/// a particular filesystem implementation.
pub(open) trait HandoffStore {
  async fn exists(Self, path : String) -> Result[Bool, String]
  async fn read(Self, path : String) -> Result[String, String]
  async fn ensure_dir(Self, path : String) -> Result[Unit, String]
  async fn write_atomic(Self, path : String, content : String) -> Result[Unit, String]
}

///|
/// Host-owned workspace adapter. Keeping workspace discovery behind this seam
/// prevents the handoff extension from reaching through another Posoco port or
/// depending on one VCS implementation.
pub(open) trait HandoffWorkspaceProbe {
  fn snapshot(Self, cwd : String) -> Result[WorkspaceSnapshot, String]
}
