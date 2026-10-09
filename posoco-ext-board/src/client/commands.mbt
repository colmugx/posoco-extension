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
      "id": id.to_json(),
      "title": title.to_json(),
      "description": description.to_json(),
      "priority": priority.to_wire().to_json(),
      "definition_of_done": definition_of_done.copy().to_json(),
      "dependencies": dependencies.copy().to_json(),
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
  let fields : Map[String, Json] = { "id": id.to_json() }
  if title is Some(value) {
    fields["title"] = value.to_json()
  }
  if description is Some(value) {
    fields["description"] = value.to_json()
  }
  if priority is Some(value) {
    fields["priority"] = value.to_wire().to_json()
  }
  if definition_of_done is Some(value) {
    fields["definition_of_done"] = value.copy().to_json()
  }
  {
    command_id,
    expected_revision,
    name: "board.task.update",
    args: Json::object(fields),
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
    args: { "id": id.to_json(), "to": to.to_wire().to_json() },
  }
}
