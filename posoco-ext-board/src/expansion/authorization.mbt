///|
/// Trusted, single-use authority. Both scopes are independently frozen.
/// Reusing this same capability in another host cannot replenish its budget.
pub struct ExpansionAuthorization {
  priv authorization_id_ : String
  priv workflow_ : String
  priv parent_ : String
  priv workflow_scope_ : Array[String]
  priv dependencies_ : Array[String]
  priv deadline_ms_ : Int64
  priv max_tasks_ : Int32
  priv max_edges_ : Int32
  priv mut used_ : Bool
}

///|
pub fn ExpansionAuthorization::ExpansionAuthorization(
  authorization_id~ : String,
  workflow~ : String,
  workflow_parent~ : String,
  workflow_task_scope~ : Array[String],
  permitted_existing_dependencies~ : Array[String] = [],
  deadline_ms~ : Int64,
  max_tasks~ : Int32 = 20,
  max_edges~ : Int32 = 60,
) -> ExpansionAuthorization {
  {
    authorization_id_: authorization_id,
    workflow_: workflow,
    parent_: workflow_parent,
    workflow_scope_: workflow_task_scope.copy(),
    dependencies_: permitted_existing_dependencies.copy(),
    deadline_ms_: deadline_ms,
    max_tasks_: max_tasks,
    max_edges_: max_edges,
    used_: false,
  }
}

///|
fn check_authority(
  auth : ExpansionAuthorization,
  now : Int64,
) -> Result[Unit, ExpansionError] {
  if now < 0L || now >= auth.deadline_ms_ {
    return Err(Expired)
  }
  if auth.max_tasks_ <= 0 ||
    auth.max_tasks_ > 20 ||
    auth.max_edges_ < 0 ||
    auth.max_edges_ > 60 {
    return Err(InvalidAuthorization("invalid budgets"))
  }
  for id in [auth.authorization_id_, auth.workflow_, auth.parent_] {
    if id.is_empty() ||
      id.length() > 128 ||
      id.iter().any(ch => ch.is_whitespace() || ch.is_control()) {
      return Err(InvalidAuthorization("invalid identity"))
    }
  }
  if auth.workflow_scope_.length() > 200 || auth.dependencies_.length() > 60 {
    return Err(InvalidAuthorization("scope bound"))
  }
  for scope in [auth.workflow_scope_, auth.dependencies_] {
    let seen : Set[String] = Set([])
    for id in scope {
      if id.is_empty() ||
        id.length() > 128 ||
        id
        .iter()
        .any(ch => ch.is_whitespace() || ch.to_int() < 32 || ch.to_int() == 127) ||
        seen.contains(id) {
        return Err(InvalidAuthorization("invalid or duplicate scope ID"))
      }
      seen.add(id)
    }
  }
  if !auth.workflow_scope_.contains(auth.parent_) {
    return Err(InvalidAuthorization("parent outside workflow task scope"))
  }
  Ok(())
}
