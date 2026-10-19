///|
/// Detached observations, never executable authority. Persisted graph records
/// and in-process scope grants deliberately remain separate fields.
pub struct BoardWorkflowView {
  snapshot : @domain.BoardStateSnapshot
  run : @dynamic.DynamicWorkflowStatus?
  executions : Array[@execution.BoardExecutionBinding]
  operation_active : Bool
  unresolved : Bool
  mutation_uncertain : Bool
  stopped : Bool
  paused : Bool
} derive(Eq, @debug.Debug)

///|
pub extend BoardWorkflowView with Eq::{equal, not_equal}

///|
pub extend BoardWorkflowView with @debug.Debug::{to_repr}

///|
pub async fn BoardWorkflows::view(
  self : BoardWorkflows,
) -> Result[BoardWorkflowView, BoardWorkflowError] {
  Ok(self.read_view()) catch {
    error => Err(safe_error(error))
  }
}

///|
async fn BoardWorkflows::read_view(self : BoardWorkflows) -> BoardWorkflowView {
  let snapshot = if self.initialized {
    self.snapshot()
  } else {
    match @store.FileBoardStore::at_directory(directory=self.directory).load() {
      Ok(loaded) => loaded.snapshot
      Err(_) => raise WorkflowFault(StoreUnavailable)
    }
  }
  let run = match self.controller {
    Some(controller) => {
      ignore(controller_result(controller.refresh_status()))
      Some(controller.status())
    }
    None => None
  }
  let executions = match self.owner {
    Some(owner) => owner.bindings()
    None =>
      match
        @journal.FileBoardExecutionStore::inspect(directory=self.directory) {
        Ok(records) => records
        Err(_) => raise WorkflowFault(StoreUnavailable)
      }
  }
  {
    snapshot,
    run,
    executions,
    operation_active: self.busy,
    unresolved: self.unresolved ||
    (
      executions.any(b => b.phase != @execution.Settled) &&
      self.controller is None
    ) ||
    self.owner.map(o => o.status().unresolved).unwrap_or(false),
    mutation_uncertain: self.uncertain,
    stopped: self.stopped,
    paused: self.paused,
  }
}

///|
pub fn BoardWorkflowView::to_json(self : BoardWorkflowView) -> Json {
  let scope = self.run.map(r => r.scope).unwrap_or([])
  let board : Json = {
    "revision": self.snapshot.revision.to_string(),
    "tasks": Json::array(
      self.snapshot.tasks.map(t => {
        (
          {
            "id": t.id.value,
            "title": t.title,
            "stage": "\{Repr(t.stage)}",
            "dependencies": Json::array(
              t.dependencies.map(d => Json::string(d.value)),
            ),
            "execution_authorized": Json::boolean(scope.contains(t.id.value)),
          } : Json)
      }),
    ),
    "attempts": Json::array(
      self.snapshot.attempts.map(a => {
        (
          {
            "id": a.id.value,
            "task_id": a.task_id.value,
            "kind": "\{Repr(a.kind)}",
            "status": "\{Repr(a.status)}",
          } : Json)
      }),
    ),
    "expansions": Json::array(
      self.snapshot.expansions.map(e => {
        (
          {
            "id": e.expansion_id.value,
            "workflow_id": e.workflow_id,
            "parent": e.parent_task_id.value,
            "mapping": Json::array(
              e.mapping.map(m => {
                ({ "key": m.local_ref, "task_id": m.task_id.value } : Json)
              }),
            ),
          } : Json)
      }),
    ),
  }
  let run = match self.run {
    None => Json::null()
    Some(r) =>
      (
        {
          "workflow_id": r.workflow_id,
          "phase": "\{Repr(r.phase)}",
          "reason": "\{Repr(r.reason)}",
          "scope_size": r.scope.length(),
          "scope": Json::array(r.scope.map(Json::string)),
          "remaining_executions": r.runner.remaining_executions,
          "remaining_ms": r.runner.remaining_ms.to_string(),
          "settled_executions": r.runner.settled,
          "remaining_expansions": r.remaining_expansions,
          "remaining_generated_tasks": r.remaining_generated_tasks,
          "generated_tasks": r.generated_tasks_committed,
          "expansions_committed": r.expansions_committed,
          "scope_authorizations": r.scope_authorizations,
          "pending_proposal": "\{Repr(r.pending_proposal_id)}",
          "expansion_phase": "\{Repr(r.expansion_phase)}",
          "partial_preparations": Json::array(
            r.partial_preparations.map(p => {
              (
                {
                  "task_id": p.task_id,
                  "attempt_id": p.attempt_id,
                  "step": "\{Repr(p.step)}",
                  "uncertain": Json::boolean(p.uncertain),
                } : Json)
            }),
          ),
          "blocked": Json::array(
            r.blocked.map(b => {
              (
                {
                  "task_id": b.task_id,
                  "reasons": Json::array(
                    b.reasons.map(reason => Json::string("\{Repr(reason)}")),
                  ),
                } : Json)
            }),
          ),
        } : Json)
  }
  {
    "board": board,
    "workflow": run,
    "operation_active": Json::boolean(self.operation_active),
    "unresolved": Json::boolean(self.unresolved),
    "mutation_uncertain": Json::boolean(self.mutation_uncertain),
    "stopped": Json::boolean(self.stopped),
    "paused": Json::boolean(self.paused),
    "executions": Json::array(
      self.executions.map(b => {
        (
          {
            "task_id": b.task_id,
            "attempt_id": b.attempt_id,
            "execution_id": b.execution_id,
            "session_id": b.session_id,
            "phase": "\{Repr(b.phase)}",
            "outcome": "\{Repr(b.outcome)}",
          } : Json)
      }),
    ),
  }
}

///|
fn policy_json(policy : BoardWorkflowPolicy) -> Json {
  {
    "max_executions": policy.max_executions,
    "max_elapsed_ms": policy.max_elapsed_ms,
    "execution_timeout_ms": policy.execution_timeout_ms,
    "max_concurrency": policy.max_concurrency,
    "max_expansions": policy.max_expansions,
    "max_generated_tasks": policy.max_generated_tasks,
    "max_depth": policy.max_depth,
    "continue_on_confirmed_failure": Json::boolean(
      policy.continue_on_confirmed_failure,
    ),
  }
}

///|
fn graph_preview_json(preview : @expansion.ExpansionApprovalPreview) -> Json {
  let draft = preview.proposal()
  {
    "proposal_id": preview.proposal_id,
    "digest": preview.digest,
    "workflow_id": preview.workflow,
    "parent_task_id": preview.workflow_parent,
    "revision": preview.revision.to_string(),
    "task_count": draft.tasks.length(),
    "maximum_edges": preview.max_edges,
    "tasks": Json::array(
      draft.tasks.map(t => {
        (
          {
            "key": t.key,
            "title": t.title,
            "description": t.description,
            "priority": "\{Repr(t.priority)}",
            "definition_of_done": Json::array(
              t.definition_of_done.map(Json::string),
            ),
            "depends_on": Json::array(
              t.depends_on.map(d => {
                match d {
                  @expansion.NewTask(key~) => ({ "local": key } : Json)
                  @expansion.ExistingTask(id~) =>
                    ({ "existing": id.value } : Json)
                }
              }),
            ),
          } : Json)
      }),
    ),
    "consequence": "Commit complete additive graph only. Created tasks have no attempts or execution authorization. No resource budget is increased.",
  }
}
