///|
/// Construct a detached snapshot record, not a committed state or a domain
/// transition. All fields are preserved verbatim; storage validates records.
pub fn ReviewEvidence::from_record(
  kind~ : ReviewEvidenceKind,
  label~ : String,
  result~ : ReviewEvidenceResult,
  detail~ : String,
) -> ReviewEvidence {
  { kind, label, result, detail, }
}

///|
/// Construct a detached snapshot record, not a committed state or a domain
/// transition. All fields are preserved verbatim; storage validates records.
pub fn ReviewArtifact::from_record(
  kind~ : ReviewArtifactKind,
  label~ : String,
  uri_or_digest~ : String,
) -> ReviewArtifact {
  { kind, label, uri_or_digest, }
}

///|
/// Construct a detached snapshot record, not a committed state or a domain
/// transition. All fields are preserved verbatim; storage validates records.
pub fn ReviewReport::from_record(
  outcome~ : String,
  summary~ : String,
  changes~ : Array[String],
  verification~ : Array[ReviewEvidence],
  risks~ : Array[String],
  notes~ : Array[String],
  open_questions~ : Array[String],
  artifacts~ : Array[ReviewArtifact],
) -> ReviewReport {
  {
    outcome,
    summary,
    changes: changes.copy(),
    verification: verification.copy(),
    risks: risks.copy(),
    notes: notes.copy(),
    open_questions: open_questions.copy(),
    artifacts: artifacts.copy(),
  }
}

///|
/// Construct a detached snapshot record, not a committed state or a domain
/// transition. All fields are preserved verbatim; storage validates records.
pub fn BoardTask::from_record(
  id~ : BoardTaskId,
  title~ : String,
  description~ : String,
  stage~ : BoardStage,
  priority~ : BoardPriority,
  definition_of_done~ : Array[String],
  dependencies~ : Array[BoardTaskId],
  created_at_ms~ : Int64,
  updated_at_ms~ : Int64,
  ready_since_ms~ : Int64?,
  model~ : ModelSelection? = None,
  review~ : ReviewReport? = None,
  review_feedback~ : String? = None,
) -> BoardTask {
  {
    id,
    title,
    description,
    stage,
    priority,
    definition_of_done: definition_of_done.copy(),
    dependencies: dependencies.copy(),
    created_at_ms,
    updated_at_ms,
    ready_since_ms,
    model,
    review: match review {
      Some(report) => Some(report.copy_detached())
      None => None
    },
    review_feedback,
  }
}

///|
/// Construct a detached snapshot record, not a committed state or a domain
/// transition. All fields are preserved verbatim; storage validates records.
pub fn Attempt::from_record(
  id~ : AttemptId,
  task_id~ : BoardTaskId,
  kind~ : AttemptKind,
  status~ : AttemptStatus,
  review~ : ReviewDecision?,
  created_at_ms~ : Int64,
  started_at_ms~ : Int64?,
  finished_at_ms~ : Int64?,
  updated_at_ms~ : Int64,
) -> Attempt {
  {
    id,
    task_id,
    kind,
    status,
    review,
    created_at_ms,
    started_at_ms,
    finished_at_ms,
    updated_at_ms,
  }
}

///|
/// Construct a detached snapshot record, not a committed state or a domain
/// transition. All fields are preserved verbatim; storage validates records.
pub fn ExpansionRecord::from_record(
  expansion_id~ : ExpansionId,
  parent_task_id~ : BoardTaskId,
  workflow_id~ : String,
  mapping~ : Array[ExpansionMapping],
  content_digest~ : String,
  created_at_ms~ : Int64,
) -> ExpansionRecord {
  {
    expansion_id,
    parent_task_id,
    workflow_id,
    mapping: mapping.copy(),
    content_digest,
    created_at_ms,
  }
}

///|
/// Deep copy of a detached snapshot, including nested task arrays and the
/// durable expansion history.
pub fn BoardStateSnapshot::copy_detached(
  self : BoardStateSnapshot,
) -> BoardStateSnapshot {
  {
    revision: self.revision,
    tasks: self.tasks.map(task => task.copy_detached()),
    attempts: self.attempts.map(attempt => attempt.copy_detached()),
    expansions: self.expansions.map(record => record.copy_detached()),
  }
}
