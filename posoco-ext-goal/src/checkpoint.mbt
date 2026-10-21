///|
/// Portable Goal state at a settled turn boundary. The host persists this
/// versioned JSON alongside the corresponding agent session transcript.
/// A checkpoint is not a replay log and does not make tool effects exactly
/// once. Resume never resends a completed turn from this snapshot.
fn cp_optional_string(value : String?) -> Json {
  match value {
    Some(s) => Json::string(s)
    None => Json::null()
  }
}

///|
fn cp_string(obj : Map[String, Json], key : String) -> Result[String, String] {
  match obj.get(key) {
    Some(Json::String(s)) => Ok(s)
    _ => Err("checkpoint missing string: " + key)
  }
}

///|
fn cp_int(obj : Map[String, Json], key : String) -> Result[Int32, String] {
  match obj.get(key) {
    Some(Json::Number(n, ..)) => {
      if n < 0.0 || n > 2147483647.0 || n.to_int().to_double() != n {
        return Err("invalid nonnegative counter: " + key)
      }
      Ok(n.to_int())
    }
    _ => Err("checkpoint missing number: " + key)
  }
}

///|
fn cp_bool(obj : Map[String, Json], key : String) -> Result[Bool, String] {
  match obj.get(key) {
    Some(Json::True) => Ok(true)
    Some(Json::False) => Ok(false)
    _ => Err("checkpoint missing boolean: " + key)
  }
}

///|
fn cp_maybe_string(obj : Map[String, Json], key : String) -> Result[String?, String] {
  match obj.get(key) {
    Some(Json::String(s)) => Ok(Some(s))
    Some(Json::Null) => Ok(None)
    _ => Err("checkpoint missing optional string: " + key)
  }
}

///|
fn cp_obj(value : Json, name : String) -> Result[Map[String, Json], String] {
  match value {
    Json::Object(fields) => Ok(fields)
    _ => Err(name + " must be an object")
  }
}

///|
pub fn GoalRunner::checkpoint(self : GoalRunner) -> Result[Json, String] {
  if self.executing_turn || self.executing_loop {
    return Err("checkpoint requires a settled, stopped goal loop")
  }
  let session = match self.active_session_id {
    Some(s) => s
    None => return Err("goal has no session to checkpoint")
  }
  match self.status {
    Paused | Running | BudgetExhausted => ()
    _ => return Err("cannot checkpoint a terminal or idle goal")
  }
  let history : Array[Json] = self.history.map(fn(item) {
    Json::object(
      Map::from_array([
        ("turn", Json::number(item.turn.to_double())),
        ("turns", Json::number(item.usage.turns.to_double())),
        ("tokens", Json::number(item.usage.total_tokens.to_double())),
        ("summary", Json::string(item.summary)),
      ]),
    )
  })
  let plan : Array[Json] = self.plan.items.map(fn(item) {
    Json::object(
      Map::from_array([
        ("title", Json::string(item.title)),
        ("status", Json::string(item.status.to_string())),
      ]),
    )
  })
  Ok(
    Json::object(
      Map::from_array([
        ("version", Json::number(1.0)),
        ("goal", Json::string(self.options.goal_condition)),
        ("session", Json::string(session)),
        ("turn", Json::number(self.current_turn.to_double())),
        ("reported_turns", Json::number(self.usage.turns.to_double())),
        ("tokens", Json::number(self.usage.total_tokens.to_double())),
        ("history", Json::array(history)),
        ("plan", Json::array(plan)),
        ("charter_delivered", Json::boolean(self.charter_delivered)),
        ("wrapup_sent", Json::boolean(self.wrapup_sent)),
        ("verifying", Json::boolean(self.verifying)),
        ("verifier_rounds", Json::number(self.verifier_rounds.to_double())),
        ("prompt_variant", Json::number(self.prompt_variant.to_double())),
        ("completion_claimed", Json::boolean(self.completion_claimed)),
        ("last_retraction", cp_optional_string(self.last_retraction)),
        ("last_stall_reason", cp_optional_string(self.last_stall_reason)),
        ("last_tool_fp", cp_optional_string(self.last_tool_fp)),
        ("repeat_count", Json::number(self.repeat_count.to_double())),
        ("stall_count", Json::number(self.stall_count.to_double())),
        ("plan_streak", Json::number(self.plan_streak.to_double())),
        ("prev_plan_fp", cp_optional_string(self.prev_plan_fp)),
      ]),
    ),
  )
}

///|
/// Restore a completed-turn snapshot into a fresh Idle runner. All fields
/// are checked before any state mutation. The caller supplies the matching
/// durable SessionStore; this API does not store the transcript itself.
pub fn GoalRunner::restore_checkpoint(
  self : GoalRunner,
  snapshot : Json,
) -> Result[Unit, String] {
  if self.executing_loop || self.status != Idle {
    return Err("checkpoint restore requires an idle runner")
  }
  let fields = match cp_obj(snapshot, "checkpoint") {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  let version = match cp_int(fields, "version") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if version != 1 {
    return Err("unsupported goal checkpoint version")
  }
  let goal = match cp_string(fields, "goal") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if goal != self.options.goal_condition {
    return Err("checkpoint goal contract mismatch")
  }
  let session = match cp_string(fields, "session") {
    Ok(v) if v != "" => v
    _ => return Err("checkpoint session is empty")
  }
  let turn = match cp_int(fields, "turn") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if self.options.budget.max_turns > 0 &&
    turn > self.options.budget.max_turns {
    return Err("checkpoint exceeds configured turn budget")
  }
  let reported_turns = match cp_int(fields, "reported_turns") {
    Ok(v) if v <= turn => v
    _ => return Err("checkpoint reported turns are invalid")
  }
  let tokens = match cp_int(fields, "tokens") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if self.options.budget.max_total_tokens > 0 &&
    tokens > self.options.budget.max_total_tokens {
    return Err("checkpoint exceeds configured token budget")
  }
  let history : Array[GoalHistoryEntry] = []
  match fields.get("history") {
    Some(Json::Array(items)) => {
      for item in items {
        let row = match cp_obj(item, "history item") {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let n = match cp_int(row, "turn") {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let t = match cp_int(row, "turns") {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let tok = match cp_int(row, "tokens") {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let summary = match cp_string(row, "summary") {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        history.push({ turn: n, usage: { turns: t, total_tokens: tok, }, summary, })
      }
    }
    _ => return Err("checkpoint history is invalid")
  }
  if history.length() != turn {
    return Err("checkpoint history does not match turn count")
  }
  let plan = match fields.get("plan") {
    Some(Json::Array(items)) =>
      match GoalPlan::from_tool_args(
        Json::object(Map::from_array([("items", Json::array(items))])),
      ) {
        Ok(v) => v
        Err(_) =>
          if items.is_empty() {
            GoalPlan::empty()
          } else {
            return Err("checkpoint plan is invalid")
          }
      }
    _ => return Err("checkpoint plan is missing")
  }
  let charter_delivered = match cp_bool(fields, "charter_delivered") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let wrapup_sent = match cp_bool(fields, "wrapup_sent") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let verifying = match cp_bool(fields, "verifying") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let verifier_rounds = match cp_int(fields, "verifier_rounds") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let prompt_variant = match cp_int(fields, "prompt_variant") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let completion_claimed = match cp_bool(fields, "completion_claimed") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let last_retraction = match cp_maybe_string(fields, "last_retraction") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let last_stall_reason = match cp_maybe_string(fields, "last_stall_reason") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let last_tool_fp = match cp_maybe_string(fields, "last_tool_fp") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let repeat_count = match cp_int(fields, "repeat_count") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let stall_count = match cp_int(fields, "stall_count") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let plan_streak = match cp_int(fields, "plan_streak") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let prev_plan_fp = match cp_maybe_string(fields, "prev_plan_fp") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // Single commit point; invalid snapshots above cannot partially mutate.
  self.current_turn = turn
  self.usage = { turns: reported_turns, total_tokens: tokens, }
  self.history = history
  self.plan = plan
  self.charter = build_charter(
    goal_condition=self.options.goal_condition,
    checklist=self.options.completion_checklist,
    completion_marker=self.options.completion_marker,
    blocked_marker=self.options.blocked_marker,
    plan_tool_name=self.options.plan_tool_name,
  )
  self.charter_delivered = charter_delivered
  self.wrapup_sent = wrapup_sent
  self.verifying = verifying
  self.verifier_rounds = verifier_rounds
  self.prompt_variant = prompt_variant
  self.completion_claimed = completion_claimed
  self.last_retraction = last_retraction
  self.last_stall_reason = last_stall_reason
  self.last_tool_fp = last_tool_fp
  self.repeat_count = repeat_count
  self.stall_count = stall_count
  self.plan_streak = plan_streak
  self.prev_plan_fp = prev_plan_fp
  self.active_session_id = Some(session)
  self.active_run_id = None
  self.assessment = Inconclusive("restored checkpoint, not verified")
  self.semantic_probability = None
  self.status = Paused
  Ok(())
}
