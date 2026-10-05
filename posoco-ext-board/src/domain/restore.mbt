///|
/// Restore a committed domain state from a detached snapshot. Restoration is
/// not a mutation: the snapshot's revision is preserved exactly, no events
/// are produced and the revision is never advanced. The snapshot's nested
/// arrays are deep-copied, so later mutation of the input cannot touch the
/// restored state.
///
/// Structural validation mirrors the storage codec: field sanity (negative
/// revision or timestamps, empty identifiers, titles or DoD items),
/// duplicate task/attempt ids, dependency existence, self-reference,
/// duplicate edges and cycles, and attempts referencing missing tasks.
/// Command FSM feasibility (stage/attempt transitions, timestamp
/// monotonicity, S4 execution coupling) is deliberately not validated.
pub fn BoardState::from_snapshot(
  snapshot : BoardStateSnapshot,
) -> Result[BoardState, BoardError] {
  match validate_restoration(snapshot) {
    Err(error) => Err(error)
    Ok(_) => {
      let state : BoardState = {
        revision: snapshot.revision,
        tasks: Map::from_array([]),
        attempts: Map::from_array([]),
      }
      for task in snapshot.tasks {
        state.tasks[task.id] = task.copy_detached()
      }
      for attempt in snapshot.attempts {
        state.attempts[attempt.id] = attempt.copy_detached()
      }
      Ok(state)
    }
  }
}

///|
/// Same phase order as the storage codec: record fields, duplicate task
/// ids, dependency edges, cycles, then attempt identity and references.
fn validate_restoration(
  snapshot : BoardStateSnapshot,
) -> Result[Unit, BoardError] {
  if snapshot.revision < 0L {
    return Err(InvalidInput(reason="revision must not be negative"))
  }
  for task in snapshot.tasks {
    match validate_restored_task(task) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
  }
  for attempt in snapshot.attempts {
    match validate_restored_attempt(attempt) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
  }
  let tasks : Map[BoardTaskId, BoardTask] = Map::from_array([])
  for task in snapshot.tasks {
    if tasks.contains(task.id) {
      return Err(DuplicateTask(task=task.id))
    }
    tasks[task.id] = task
  }
  for task in snapshot.tasks {
    match validate_restored_dependencies(tasks, task) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
  }
  match restored_dependency_cycle(tasks, snapshot.tasks.map(task => task.id)) {
    Some(cycle) => return Err(DependencyCycle(cycle~))
    None => ()
  }
  let attempt_ids : Set[AttemptId] = Set::from_array([])
  for attempt in snapshot.attempts {
    if attempt_ids.contains(attempt.id) {
      return Err(DuplicateAttempt(attempt=attempt.id))
    }
    if tasks.get(attempt.task_id) is None {
      return Err(TaskMissing(task=attempt.task_id))
    }
    attempt_ids.add(attempt.id)
  }
  Ok(())
}

///|
fn validate_restored_task(task : BoardTask) -> Result[Unit, BoardError] {
  if task.id.value == "" {
    return Err(InvalidInput(reason="task id must not be empty"))
  }
  if task.title == "" {
    return Err(InvalidInput(reason="title must not be empty"))
  }
  if task.created_at_ms < 0L {
    return Err(InvalidInput(reason="created_at_ms must not be negative"))
  }
  if task.updated_at_ms < 0L {
    return Err(InvalidInput(reason="updated_at_ms must not be negative"))
  }
  match task.ready_since_ms {
    Some(at_ms) if at_ms < 0L =>
      return Err(InvalidInput(reason="ready_since_ms must not be negative"))
    _ => ()
  }
  for item in task.definition_of_done {
    if item == "" {
      return Err(
        InvalidInput(reason="definition_of_done items must not be empty"),
      )
    }
  }
  for dependency in task.dependencies {
    if dependency.value == "" {
      return Err(InvalidInput(reason="dependency id must not be empty"))
    }
  }
  Ok(())
}

///|
fn validate_restored_attempt(attempt : Attempt) -> Result[Unit, BoardError] {
  if attempt.id.value == "" {
    return Err(InvalidInput(reason="attempt id must not be empty"))
  }
  if attempt.task_id.value == "" {
    return Err(InvalidInput(reason="task id must not be empty"))
  }
  if attempt.created_at_ms < 0L {
    return Err(InvalidInput(reason="created_at_ms must not be negative"))
  }
  if attempt.updated_at_ms < 0L {
    return Err(InvalidInput(reason="updated_at_ms must not be negative"))
  }
  match attempt.started_at_ms {
    Some(at_ms) if at_ms < 0L =>
      return Err(InvalidInput(reason="started_at_ms must not be negative"))
    _ => ()
  }
  match attempt.finished_at_ms {
    Some(at_ms) if at_ms < 0L =>
      return Err(InvalidInput(reason="finished_at_ms must not be negative"))
    _ => ()
  }
  Ok(())
}

///|
fn validate_restored_dependencies(
  tasks : Map[BoardTaskId, BoardTask],
  task : BoardTask,
) -> Result[Unit, BoardError] {
  let seen : Set[BoardTaskId] = Set::from_array([])
  for dependency in task.dependencies {
    if dependency == task.id {
      return Err(SelfDependency(task=task.id))
    }
    if tasks.get(dependency) is None {
      return Err(DependencyMissing(task=task.id, dependency~))
    }
    if seen.contains(dependency) {
      return Err(DuplicateDependency(task=task.id, dependency~))
    }
    seen.add(dependency)
  }
  Ok(())
}

///|
/// Deterministic DFS over the restored dependency graph in snapshot task
/// order, visiting edges in declaration order. Returns the path from the
/// first revisited task to the closing edge, matching the `DependencyCycle`
/// shape propose produces.
fn restored_dependency_cycle(
  tasks : Map[BoardTaskId, BoardTask],
  order : Array[BoardTaskId],
) -> Array[BoardTaskId]? {
  let colors : Map[BoardTaskId, Int] = Map::from_array([])
  let path : Array[BoardTaskId] = []
  fn visit(id : BoardTaskId) -> Array[BoardTaskId]? {
    match colors.get(id) {
      Some(2) => return None
      Some(_) => {
        for start, node in path {
          if node == id {
            return Some(path[start:].to_owned())
          }
        }
        return None
      }
      None => ()
    }
    colors[id] = 1
    path.push(id)
    match tasks.get(id) {
      Some(task) =>
        for dependency in task.dependencies {
          match visit(dependency) {
            Some(cycle) => return Some(cycle)
            None => ()
          }
        }
      None => ()
    }
    let _ = path.remove(path.length() - 1)
    colors[id] = 2
    None
  }
  for id in order {
    match visit(id) {
      Some(cycle) => return Some(cycle)
      None => ()
    }
  }
  None
}
