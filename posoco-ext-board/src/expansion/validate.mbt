///|
/// Counts are read from one authoritative snapshot, never an in-memory reset.
fn workflow_usage(
  snapshot : @domain.BoardStateSnapshot,
  workflow : String,
) -> (Int32, Int32) {
  let mut expansions = 0
  let mut tasks = 0
  for record in snapshot.expansions {
    if record.workflow_id == workflow {
      expansions += 1
      tasks += record.mapping.length()
    }
  }
  (expansions, tasks)
}

///|
fn graph_candidates(
  draft : DraftExpansion,
  mapping : Array[(String, @domain.BoardTaskId)],
) -> Array[@domain.GraphTask] {
  let ids : Map[String, @domain.BoardTaskId] = Map(mapping)
  draft.tasks.map(task => {
    @domain.GraphTask::from_record(
      id=ids[task.key],
      title=task.title,
      description=task.description,
      priority=task.priority,
      definition_of_done=task.definition_of_done,
      dependencies=task.depends_on.map(dep => {
        match dep {
          NewTask(key~) => ids[key]
          ExistingTask(id~) => id
        }
      }),
      local_ref=task.key,
    )
  })
}

///|
/// Side-effect-free validation. The sole DAG engine is the domain's whole-
/// proposal preview, restoring the actual snapshot rather than reseeding tasks.
fn validate_expansion(
  draft : DraftExpansion,
  snapshot : @domain.BoardStateSnapshot,
  auth : ExpansionAuthorization,
  policy : ExpansionPolicy,
  now : Int64,
) -> Result[Unit, ExpansionError] {
  match check_authority(auth, now) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if draft.parent_task_id != auth.parent_ {
    return Err(InvalidAuthorization("parent mismatch"))
  }
  if snapshot.expansions.any(r => r.expansion_id.value == draft.proposal_id) {
    return Err(DuplicateProposal)
  }
  if draft.base_revision != snapshot.revision {
    return Err(StalePreview)
  }
  if draft.tasks.length() > auth.max_tasks_ ||
    draft.tasks.length() > policy.max_tasks() ||
    draft.tasks.is_empty() {
    return Err(PolicyBudgetExceeded("task budget"))
  }
  let (expansions, tasks) = workflow_usage(snapshot, auth.workflow_)
  if expansions >= policy.max_workflow_expansions() ||
    tasks + draft.tasks.length() > policy.max_workflow_tasks() {
    return Err(PolicyBudgetExceeded("workflow budget"))
  }
  let keys : Set[String] = Set([])
  for task in draft.tasks {
    if keys.contains(task.key) {
      return Err(InvalidProposal("duplicate local key"))
    }
    keys.add(task.key)
  }
  let mut edges = 0
  for task in draft.tasks {
    edges += task.depends_on.length()
    for dep in task.depends_on {
      match dep {
        NewTask(key~) =>
          if !keys.contains(key) {
            return Err(InvalidProposal("unknown local dependency"))
          }
        ExistingTask(id~) =>
          if !auth.dependencies_.contains(id.value) {
            return Err(
              InvalidAuthorization("existing dependency not permitted"),
            )
          }
      }
    }
  }
  if edges > auth.max_edges_ || edges > policy.max_edges() {
    return Err(PolicyBudgetExceeded("edge budget"))
  }
  // Temporary validation identities are not canonical allocations. Avoid every
  // existing ID; explicit local/existing tags prevent namespace capture.
  let existing = snapshot.tasks.map(t => t.id.value)
  let mapping : Array[(String, @domain.BoardTaskId)] = []
  for task in draft.tasks {
    let mut id = "s4e1-preview:" + task.key
    while existing.contains(id) {
      id = ":" + id
    }
    mapping.push((task.key, @domain.BoardTaskId(id)))
  }
  let candidates = graph_candidates(draft, mapping)
  match
    @domain.BoardDomain::preview_expand_graph(
      snapshot,
      expansion=@domain.ExpansionId(draft.proposal_id),
      candidates~,
      parent=@domain.BoardTaskId(auth.parent_),
      workflow=auth.workflow_,
      at_ms=now,
      expected_revision=draft.base_revision,
    ) {
    Err(error) => return Err(DomainRejected(error))
    Ok(_) => ()
  }
  // A bounded depth walk is a resource policy, not a second cycle validator:
  // the domain has already proved this combined graph acyclic and complete.
  let dependencies : Map[String, Array[String]] = Map([])
  for task in snapshot.tasks {
    dependencies[task.id.value] = task.dependencies.map(id => id.value)
  }
  for candidate in candidates {
    dependencies[candidate.id.value] = candidate.dependencies.map(id => id.value)
  }
  let mut frontier = candidates.map(candidate => candidate.id.value)
  for _ in 0..<policy.max_depth() {
    let next : Set[String] = Set([])
    for id in frontier {
      for dependency in dependencies[id] {
        next.add(dependency)
      }
    }
    frontier = next.iter().collect()
    if frontier.is_empty() {
      return Ok(())
    }
  }
  Err(PolicyBudgetExceeded("graph depth budget"))
}
