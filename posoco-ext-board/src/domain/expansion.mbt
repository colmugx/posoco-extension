///|
/// S4E1 core atomic graph expansion: detached candidate input, the durable
/// expansion record and the pure preview helper. The raw proposal text of a
/// model or planner never enters the domain; the identity binding is the
/// normalized content digest documented in `docs/S4E1-dynamic-expansion.md`.

///|
/// Detached candidate task input for one graph expansion. The domain owns
/// the resulting task's stage (`Created`), its timestamps and
/// `ready_since_ms`; callers never supply them. `local_ref` is the
/// planner-side reference that the committed `ExpansionRecord` maps to the
/// canonical task id.
pub struct GraphTask {
  id : BoardTaskId
  title : String
  description : String
  priority : BoardPriority
  definition_of_done : Array[String]
  dependencies : Array[BoardTaskId]
  local_ref : String
} derive(Eq, Debug)

///|
pub extend GraphTask with Eq::{equal, not_equal}

///|
pub extend GraphTask with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Construct a detached candidate input; both arrays are duplicated, so a
/// caller that mutates them after submission cannot alter what a later
/// reader validates against.
pub fn GraphTask::from_record(
  id~ : BoardTaskId,
  title~ : String,
  description~ : String,
  priority~ : BoardPriority,
  definition_of_done~ : Array[String],
  dependencies~ : Array[BoardTaskId],
  local_ref~ : String,
) -> GraphTask {
  {
    id,
    title,
    description,
    priority,
    definition_of_done: definition_of_done.copy(),
    dependencies: dependencies.copy(),
    local_ref,
  }
}

///|
/// Deep copy of the detached candidate, including both nested arrays.
pub fn GraphTask::copy_detached(self : GraphTask) -> GraphTask {
  {
    ..self,
    definition_of_done: self.definition_of_done.copy(),
    dependencies: self.dependencies.copy(),
  }
}

///|
/// One ordered local reference to canonical ID binding.
pub(all) struct ExpansionMapping {
  local_ref : String
  task_id : BoardTaskId
} derive(Eq, Debug)

///|
pub extend ExpansionMapping with Eq::{equal, not_equal}

///|
pub extend ExpansionMapping with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One durable whole-proposal identity. No raw proposal text is retained.
pub struct ExpansionRecord {
  expansion_id : ExpansionId
  parent_task_id : BoardTaskId
  workflow_id : String
  mapping : Array[ExpansionMapping]
  content_digest : String
  created_at_ms : Int64
} derive(Eq, Debug)

///|
pub extend ExpansionRecord with Eq::{equal, not_equal}

///|
pub extend ExpansionRecord with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Detached copy of a record, including the complete mapping array.
pub fn ExpansionRecord::copy_detached(
  self : ExpansionRecord,
) -> ExpansionRecord {
  { ..self, mapping: self.mapping.copy(), }
}

///|
/// Outcome of the pure expansion preview: the exact content binding the
/// domain would commit and the record it would append. No state is mutated
/// and nothing is persisted.
pub(all) struct ExpansionPreview {
  digest : String
  record : ExpansionRecord
} derive(Eq, Debug)

///|
pub extend ExpansionPreview with Eq::{equal, not_equal}

///|
pub extend ExpansionPreview with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Length-framed exact normalized content, encoded with UTF-8 and SHA256.
/// Array order is significant; no whitespace or Unicode normalization is hidden.
fn digest_field(buffer : StringBuilder, text : String) -> Unit {
  buffer.write_string(@utf8.encode(text).length().to_string())
  buffer.write_string(":")
  buffer.write_string(text)
}

///|
pub fn expansion_content_digest(
  expansion~ : ExpansionId,
  candidates~ : Array[GraphTask],
  parent~ : BoardTaskId,
  workflow~ : String,
) -> String {
  let buffer = StringBuilder()
  digest_field(buffer, "s4e1-expansion-v2")
  digest_field(buffer, expansion.value)
  digest_field(buffer, parent.value)
  digest_field(buffer, workflow)
  digest_field(buffer, candidates.length().to_string())
  for candidate in candidates {
    digest_field(buffer, candidate.local_ref)
    digest_field(buffer, candidate.id.value)
    digest_field(buffer, candidate.title)
    digest_field(buffer, candidate.description)
    digest_field(buffer, candidate.priority.rank().to_string())
    digest_field(buffer, candidate.definition_of_done.length().to_string())
    for item in candidate.definition_of_done {
      digest_field(buffer, item)
    }
    digest_field(buffer, candidate.dependencies.length().to_string())
    for dependency in candidate.dependencies {
      digest_field(buffer, dependency.value)
    }
  }
  "sha256:" +
  @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(buffer.to_string())))
}

///|
pub fn valid_expansion_digest(digest : String) -> Bool {
  if digest.length() != 71 || !digest.has_prefix("sha256:") {
    return false
  }
  for ch in digest[7:] {
    if !(ch >= '0' && ch <= '9') && !(ch >= 'a' && ch <= 'f') {
      return false
    }
  }
  true
}

///|
fn validate_expansion_input(
  expansion : ExpansionId,
  candidates : Array[GraphTask],
  workflow : String,
  at_ms : Int64,
) -> BoardError? {
  if expansion.value.trim().is_empty() {
    return Some(InvalidInput(reason="expansion id must not be empty"))
  }
  if workflow.trim().is_empty() {
    return Some(InvalidInput(reason="workflow id must not be empty"))
  }
  if invalid_time(at_ms) {
    return Some(InvalidInput(reason="created_at_ms must not be negative"))
  }
  if candidates.is_empty() {
    return Some(InvalidInput(reason="expansion must contain tasks"))
  }
  let refs : Set[String] = Set::from_array([])
  for candidate in candidates {
    if candidate.local_ref.trim().is_empty() {
      return Some(InvalidInput(reason="expansion local_ref must not be empty"))
    }
    if refs.contains(candidate.local_ref) {
      return Some(InvalidInput(reason="duplicate expansion local_ref"))
    }
    refs.add(candidate.local_ref)
    if candidate.id.value.trim().is_empty() {
      return Some(InvalidInput(reason="task id must not be empty"))
    }
    if candidate.title == "" {
      return Some(InvalidInput(reason="title must not be empty"))
    }
    for item in candidate.definition_of_done {
      if item == "" {
        return Some(
          InvalidInput(reason="definition_of_done items must not be empty"),
        )
      }
    }
  }
  None
}

///|
fn expansion_record(
  expansion~ : ExpansionId,
  candidates~ : Array[GraphTask],
  parent~ : BoardTaskId,
  workflow~ : String,
  digest~ : String,
  at_ms~ : Int64,
) -> ExpansionRecord {
  {
    expansion_id: expansion,
    parent_task_id: parent,
    workflow_id: workflow,
    mapping: candidates.map(candidate => {
      local_ref: candidate.local_ref,
      task_id: candidate.id,
    }),
    content_digest: digest,
    created_at_ms: at_ms,
  }
}

///|
/// Pure preview of one graph expansion against a detached snapshot: it
/// validates the request through the exact command path (restore plus
/// propose, including the shared DAG validator) and answers the content
/// binding plus the record a commit would append, without mutating or
/// persisting anything.
pub fn BoardDomain::preview_expand_graph(
  snapshot : BoardStateSnapshot,
  expansion~ : ExpansionId,
  candidates~ : Array[GraphTask],
  parent~ : BoardTaskId,
  workflow~ : String,
  at_ms~ : Int64,
  expected_revision~ : Int64,
) -> Result[ExpansionPreview, BoardError] {
  let state = match BoardState::from_snapshot(snapshot) {
    Ok(state) => state
    Err(error) => return Err(error)
  }
  let proposal = match
    BoardDomain::propose(
      state,
      ExpandGraph(
        expansion~,
        candidates=candidates.map(candidate => candidate.copy_detached()),
        parent~,
        workflow~,
        at_ms~,
        expected_revision~,
      ),
    ) {
    Ok(proposal) => proposal
    Err(error) => return Err(error)
  }
  let record = match proposal.next_state.expansion(expansion) {
    Some(record) => record
    None => abort("expansion preview: committed record missing")
  }
  Ok({ digest: record.content_digest, record, })
}
