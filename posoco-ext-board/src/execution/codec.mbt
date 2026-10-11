///|
fn phase_wire(phase : BoardExecutionPhase) -> String {
  match phase {
    Reserved => "reserved"
    Running => "running"
    Finished => "finished"
    Settled => "settled"
    Unresolved => "unresolved"
  }
}

///|
fn result_wire(outcome : BoardExecutionOutcome) -> String {
  match outcome {
    Completed => "completed"
    Failed => "failed"
    Cancelled => "cancelled"
    TimedOut => "timed_out"
    Interrupted => "interrupted"
  }
}

///|
fn valid_bindings(records : Array[BoardExecutionBinding]) -> Bool {
  let attempts : Map[String, Unit] = Map([])
  let executions : Map[String, Unit] = Map([])
  let sessions : Map[String, Unit] = Map([])
  for record in records {
    if !valid_identity(record.task_id) ||
      !valid_identity(record.attempt_id) ||
      !valid_identity(record.execution_id) ||
      !valid_identity(record.session_id) ||
      attempts.contains(record.attempt_id) ||
      executions.contains(record.execution_id) ||
      sessions.contains(record.session_id) {
      return false
    }
    attempts[record.attempt_id] = ()
    executions[record.execution_id] = ()
    sessions[record.session_id] = ()
    match record.run {
      Some(run) if run.session_id != record.session_id ||
        !valid_identity(run.run_id) ||
        !valid_identity(run.turn_id) => return false
      _ => ()
    }
    match record.phase {
      Running if record.run is None || record.outcome is Some(_) => return false
      Reserved if record.outcome is Some(_) => return false
      Finished | Settled if record.run is None || record.outcome is None =>
        return false
      _ => ()
    }
  }
  true
}

///|
/// Version 1 is a separate identity journal; it contains no Board snapshot or
/// execution inputs. Unknown fields/versions fail closed.
///
/// ```mbt check
/// test {
///   assert_true(@execution.encode_execution_journal([]) is Ok(_))
/// }
/// ```
pub fn encode_execution_journal(
  records : Array[BoardExecutionBinding],
) -> Result[String, BoardExecutionError] {
  if !valid_bindings(records) {
    return Err(StoreUnavailable)
  }
  let items = records.map(record => {
    let run : Json = match record.run {
      None => Json::null()
      Some(run) =>
        {
          "session_id": run.session_id,
          "run_id": run.run_id,
          "turn_id": run.turn_id,
        }
    }
    let outcome : Json = match record.outcome {
      None => Json::null()
      Some(outcome) => Json::string(result_wire(outcome))
    }
    Json::object({
      "task_id": Json::string(record.task_id),
      "attempt_id": Json::string(record.attempt_id),
      "execution_id": Json::string(record.execution_id),
      "session_id": Json::string(record.session_id),
      "run": run,
      "phase": Json::string(phase_wire(record.phase)),
      "outcome": outcome,
    })
  })
  Ok(
    Json::object({
      "schema_version": Json::number(1),
      "bindings": Json::array(items),
    }).stringify(),
  )
}

///|
priv suberror JournalInvalid {
  Invalid
}

///|
fn fields(
  value : Json,
  allowed : Array[String],
) -> Map[String, Json] raise JournalInvalid {
  guard value is Object(fields) else { raise Invalid }
  if fields.length() != allowed.length() {
    raise Invalid
  }
  for key in fields.keys() {
    if !allowed.contains(key) {
      raise Invalid
    }
  }
  fields
}

///|
fn text(
  fields : Map[String, Json],
  key : String,
) -> String raise JournalInvalid {
  match fields.get(key) {
    Some(String(value)) => value
    _ => raise Invalid
  }
}

///|
fn parse_binding(value : Json) -> BoardExecutionBinding raise JournalInvalid {
  let values = fields(value, [
    "task_id", "attempt_id", "execution_id", "session_id", "run", "phase", "outcome",
  ])
  let phase = match text(values, "phase") {
    "reserved" => Reserved
    "running" => Running
    "finished" => Finished
    "settled" => Settled
    "unresolved" => Unresolved
    _ => raise Invalid
  }
  let outcome = match values.get("outcome") {
    Some(Null) => None
    Some(String(value)) =>
      Some(
        match value {
          "completed" => Completed
          "failed" => Failed
          "cancelled" => Cancelled
          "timed_out" => TimedOut
          "interrupted" => Interrupted
          _ => raise Invalid
        },
      )
    _ => raise Invalid
  }
  let run = match values.get("run") {
    Some(Null) => None
    Some(value) => {
      let data = fields(value, ["session_id", "run_id", "turn_id"])
      Some({
        session_id: text(data, "session_id"),
        run_id: text(data, "run_id"),
        turn_id: text(data, "turn_id"),
      })
    }
    _ => raise Invalid
  }
  {
    task_id: text(values, "task_id"),
    attempt_id: text(values, "attempt_id"),
    execution_id: text(values, "execution_id"),
    session_id: text(values, "session_id"),
    run,
    phase,
    outcome,
  }
}

///|
/// Strict decode never interprets a recovered binding as permission to rerun.
///
/// ```mbt check
/// test {
///   assert_eq(
///     @execution.decode_execution_journal(
///       "{\"schema_version\":1,\"bindings\":[]}",
///     ),
///     Ok([]),
///   )
/// }
/// ```
pub fn decode_execution_journal(
  source : String,
) -> Result[Array[BoardExecutionBinding], BoardExecutionError] {
  let parsed = @json.parse(source) catch { _ => return Err(StoreUnavailable) }
  let records = try {
    let values = fields(parsed, ["schema_version", "bindings"])
    guard values.get("schema_version") is Some(Number(1, ..)) else {
      raise Invalid
    }
    guard values.get("bindings") is Some(Array(items)) else { raise Invalid }
    items.map(parse_binding)
  } catch {
    _ => return Err(StoreUnavailable)
  }
  if valid_bindings(records) {
    Ok(records)
  } else {
    Err(StoreUnavailable)
  }
}
