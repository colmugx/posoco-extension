///|
/// Canonical v1 priority spelling, shared by every client command builder.
///
/// ```mbt check
/// test {
///   let priority : @client.ClientBoardPriority = @client.High
///   assert_eq(priority.to_wire(), "high")
/// }
/// ```
pub fn ClientBoardPriority::to_wire(self : ClientBoardPriority) -> String {
  match self {
    Low => "low"
    Normal => "normal"
    High => "high"
    Critical => "critical"
  }
}

///|
/// Canonical v1 stage spelling, not a client-side transition validator.
///
/// ```mbt check
/// test {
///   let stage : @client.ClientBoardStage = @client.Ready
///   assert_eq(stage.to_wire(), "ready")
/// }
/// ```
pub fn ClientBoardStage::to_wire(self : ClientBoardStage) -> String {
  match self {
    Created => "created"
    Refining => "refining"
    Ready => "ready"
    Running => "running"
    Review => "review"
    Done => "done"
    Suspended => "suspended"
    Cancelled => "cancelled"
  }
}

///|
/// Build intent only: command IDs correlate responses, never authorize retries.
/// The caller supplies the authoritative revision and the explicit task ID;
/// timestamps and semantic validation belong to the server.
///
/// ```mbt check
/// test {
///   let wire = @client.create_task_command(
///     "cmd-1",
///     0L,
///     id="task-1",
///     title="Ship",
///     description="",
///     priority=@client.Normal,
///     definition_of_done=["Tests pass"],
///     dependencies=[],
///   )
///   assert_eq(wire.name, "board.task.create")
///   assert_eq(wire.expected_revision, 0L)
/// }
/// ```
pub fn create_task_command(
  command_id : String,
  expected_revision : Int64,
  id~ : String,
  title~ : String,
  description~ : String,
  priority~ : ClientBoardPriority,
  definition_of_done~ : Array[String],
  dependencies~ : Array[String],
) -> @protocol.BoardClientCommand {
  {
    command_id,
    expected_revision,
    name: "board.task.create",
    args: {
      "id": Json(id),
      "title": Json(title),
      "description": Json(description),
      "priority": Json(priority.to_wire()),
      "definition_of_done": Json(definition_of_done.copy()),
      "dependencies": Json(dependencies.copy()),
    },
  }
}

///|
/// Omitted fields stay absent; an empty DoD array explicitly clears it.
/// Dependencies, stage and server metadata cannot enter these arguments.
///
/// ```mbt check
/// test {
///   let wire = @client.update_task_command("cmd-2", 1L, id="task-1", definition_of_done=[])
///   assert_eq(wire.args, { "id": "task-1", "definition_of_done": [] })
/// }
/// ```
pub fn update_task_command(
  command_id : String,
  expected_revision : Int64,
  id~ : String,
  title? : String,
  description? : String,
  priority? : ClientBoardPriority,
  definition_of_done? : Array[String],
) -> @protocol.BoardClientCommand {
  let fields : Map[String, Json] = { "id": Json(id) }
  if title is Some(value) {
    fields["title"] = Json(value)
  }
  if description is Some(value) {
    fields["description"] = Json(value)
  }
  if priority is Some(value) {
    fields["priority"] = Json(value.to_wire())
  }
  if definition_of_done is Some(value) {
    fields["definition_of_done"] = Json(value.copy())
  }
  {
    command_id,
    expected_revision,
    name: "board.task.update",
    args: Json::object(fields),
  }
}

///|
/// Replace the complete dependency set for one task. The durable server owns
/// existence, duplicate/self-edge and DAG-cycle validation; clients only send
/// explicit task IDs against the current authoritative revision.
///
/// ```mbt check
/// test {
///   let wire = @client.set_task_dependencies_command(
///     "cmd-deps",
///     2L,
///     id="task-1",
///     dependencies=["task-2", "task-3"],
///   )
///   assert_eq(wire.name, "board.task.set_dependencies")
///   assert_eq(wire.args, { "id": "task-1", "dependencies": ["task-2", "task-3"] })
/// }
/// ```
pub fn set_task_dependencies_command(
  command_id : String,
  expected_revision : Int64,
  id~ : String,
  dependencies~ : Array[String],
) -> @protocol.BoardClientCommand {
  {
    command_id,
    expected_revision,
    name: "board.task.set_dependencies",
    args: { "id": Json(id), "dependencies": Json(dependencies.copy()) },
  }
}

///|
/// Pin or clear one ticket's model. The host validates the slot against the
/// current modelport catalog; `model=None` is an explicit clear.
pub fn set_task_model_command(
  command_id : String,
  expected_revision : Int64,
  id~ : String,
  model~ : ClientModelSelection?,
) -> @protocol.BoardClientCommand {
  {
    command_id,
    expected_revision,
    name: "board.task.set_model",
    args: {
      "id": Json(id),
      "model": match model {
        Some(value) =>
          Json::object({
            "slot": Json(value.slot),
            "effort": match value.effort {
              Some(effort) => Json(effort)
              None => Json::null()
            },
          })
        None => Json::null()
      },
    },
  }
}

///|
/// Canonical v1 attempt kind spelling, shared by every attempt builder.
///
/// ```mbt check
/// test {
///   let kind : @client.ClientAttemptKind = @client.Execute
///   assert_eq(kind.to_wire(), "execute")
/// }
/// ```
pub fn ClientAttemptKind::to_wire(self : ClientAttemptKind) -> String {
  match self {
    Discuss => "discuss"
    Execute => "execute"
    Review => "review"
  }
}

///|
/// Canonical v1 terminal outcome spelling; `queued`/`running` statuses are
/// never wire outcomes.
///
/// ```mbt check
/// test {
///   let outcome : @client.ClientAttemptOutcome = @client.Succeeded
///   assert_eq(outcome.to_wire(), "succeeded")
/// }
/// ```
pub fn ClientAttemptOutcome::to_wire(self : ClientAttemptOutcome) -> String {
  match self {
    Succeeded => "succeeded"
    Failed => "failed"
    Cancelled => "cancelled"
    Interrupted => "interrupted"
  }
}

///|
/// Canonical v1 recordable review spelling. `pending` is deliberately not a
/// wire decision: it is the implicit state when a review attempt starts
/// running, so only the two terminal decisions convert.
///
/// ```mbt check
/// test {
///   let decision : @client.ClientRecordableReviewDecision = @client.Approved
///   assert_eq(decision.to_wire(), "approved")
/// }
/// ```
pub fn ClientRecordableReviewDecision::to_wire(
  self : ClientRecordableReviewDecision,
) -> String {
  match self {
    Approved => "approved"
    ChangesRequested => "changes_requested"
  }
}

///|
/// Queue a new attempt against an explicit task. The attempt ID is
/// client-provided and correlated by the server's duplicate rejection; the
/// durable server owns task existence and kind semantics.
///
/// ```mbt check
/// test {
///   let wire = @client.queue_attempt_command(
///     "cmd-queue",
///     2L,
///     id="attempt-1",
///     task_id="task-1",
///     kind=@client.Discuss,
///   )
///   assert_eq(wire.name, "board.attempt.queue")
///   assert_eq(wire.args, {
///     "id": "attempt-1",
///     "task_id": "task-1",
///     "kind": "discuss",
///   })
/// }
/// ```
pub fn queue_attempt_command(
  command_id : String,
  expected_revision : Int64,
  id~ : String,
  task_id~ : String,
  kind~ : ClientAttemptKind,
) -> @protocol.BoardClientCommand {
  {
    command_id,
    expected_revision,
    name: "board.attempt.queue",
    args: {
      "id": Json(id),
      "task_id": Json(task_id),
      "kind": Json(kind.to_wire()),
    },
  }
}

///|
/// Start one queued attempt; only the explicit attempt ID is sent.
///
/// ```mbt check
/// test {
///   let wire = @client.start_attempt_command("cmd-start", 3L, id="attempt-1")
///   assert_eq(wire.name, "board.attempt.start")
///   assert_eq(wire.args, { "id": "attempt-1" })
/// }
/// ```
pub fn start_attempt_command(
  command_id : String,
  expected_revision : Int64,
  id~ : String,
) -> @protocol.BoardClientCommand {
  {
    command_id,
    expected_revision,
    name: "board.attempt.start",
    args: { "id": Json(id) },
  }
}

///|
/// Finish one running attempt with an explicit terminal outcome; the
/// terminal choice is never inferred or defaulted by this builder.
///
/// ```mbt check
/// test {
///   let wire = @client.finish_attempt_command(
///     "cmd-finish",
///     4L,
///     id="attempt-1",
///     outcome=@client.Cancelled,
///   )
///   assert_eq(wire.name, "board.attempt.finish")
///   assert_eq(wire.args, { "id": "attempt-1", "outcome": "cancelled" })
/// }
/// ```
pub fn finish_attempt_command(
  command_id : String,
  expected_revision : Int64,
  id~ : String,
  outcome~ : ClientAttemptOutcome,
) -> @protocol.BoardClientCommand {
  {
    command_id,
    expected_revision,
    name: "board.attempt.finish",
    args: { "id": Json(id), "outcome": Json(outcome.to_wire()) },
  }
}

///|
/// Record one terminal review decision on a running Review attempt; the
/// decision type has no Pending case, so `pending` can never be encoded.
/// Only the explicit attempt ID and decision are sent; timestamps and
/// semantic validation belong to the server.
///
/// ```mbt check
/// test {
///   let wire = @client.record_review_command(
///     "cmd-review",
///     5L,
///     id="attempt-1",
///     decision=@client.ChangesRequested,
///   )
///   assert_eq(wire.name, "board.review.record")
///   assert_eq(wire.args, { "id": "attempt-1", "decision": "changes_requested" })
/// }
/// ```
pub fn record_review_command(
  command_id : String,
  expected_revision : Int64,
  id~ : String,
  decision~ : ClientRecordableReviewDecision,
) -> @protocol.BoardClientCommand {
  {
    command_id,
    expected_revision,
    name: "board.review.record",
    args: { "id": Json(id), "decision": Json(decision.to_wire()) },
  }
}

///|
/// Request a stage transition; the durable server remains authoritative.
///
/// ```mbt check
/// test {
///   let wire = @client.move_task_command(
///     "cmd-3",
///     2L,
///     id="task-1",
///     to=@client.Refining,
///   )
///   assert_eq(wire.args, { "id": "task-1", "to": "refining" })
/// }
/// ```
pub fn move_task_command(
  command_id : String,
  expected_revision : Int64,
  id~ : String,
  to~ : ClientBoardStage,
) -> @protocol.BoardClientCommand {
  {
    command_id,
    expected_revision,
    name: "board.task.move",
    args: { "id": Json(id), "to": Json(to.to_wire()) },
  }
}

///|
pub fn delete_task_command(
  command_id : String,
  expected_revision : Int64,
  id~ : String,
) -> @protocol.BoardClientCommand {
  {
    command_id,
    expected_revision,
    name: "board.task.delete",
    args: { "id": Json(id) },
  }
}
