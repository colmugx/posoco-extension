///|
async test "canonical task and attempt command fixtures match client builders and strict server schema" {
  let directory = fixture_directory()
  let description = "Share wire fixtures across browser and desktop clients."
  let dod = [
    "Decode every v1 server frame", "Apply the authoritative projection",
  ]
  let id = @domain.BoardTaskId("task-1")
  let at_ms = 1234L
  let cases : Array[
    (String, @protocol.BoardClientCommand, @domain.BoardCommand),
  ] = [
    (
      "task-create-command",
      @client.create_task_command(
        "cmd-create-1",
        0L,
        id="task-1",
        title="Validate the Board contract",
        description~,
        priority=@client.Normal,
        definition_of_done=dod,
        dependencies=[],
      ),
      @domain.CreateTask(
        id~,
        title="Validate the Board contract",
        description~,
        priority=@domain.Normal,
        definition_of_done=dod,
        dependencies=[],
        at_ms~,
        expected_revision=0L,
      ),
    ),
    (
      "task-update-command",
      @client.update_task_command(
        "cmd-update-1",
        1L,
        id="task-1",
        title="Validate the Board contract — v1",
        description~,
        priority=@client.High,
        definition_of_done=[],
      ),
      @domain.UpdateTask(
        id~,
        title=Some("Validate the Board contract — v1"),
        description=Some(description),
        priority=Some(@domain.High),
        definition_of_done=Some([]),
        at_ms~,
        expected_revision=1L,
      ),
    ),
    (
      "task-set-dependencies-command",
      @client.set_task_dependencies_command("cmd-deps-1", 2L, id="task-1", dependencies=[
        "task-2",
      ]),
      @domain.SetDependencies(
        id~,
        dependencies=[@domain.BoardTaskId("task-2")],
        at_ms~,
        expected_revision=2L,
      ),
    ),
    (
      "task-move-command",
      @client.move_task_command(
        "cmd-move-1",
        2L,
        id="task-1",
        to=@client.Refining,
      ),
      @domain.MoveTask(id~, to=@domain.Refining, at_ms~, expected_revision=2L),
    ),
    (
      "attempt-queue-command",
      @client.queue_attempt_command(
        "cmd-queue-1",
        2L,
        id="attempt-2",
        task_id="task-1",
        kind=@client.Execute,
      ),
      @domain.QueueAttempt(
        id=@domain.AttemptId("attempt-2"),
        task=id,
        kind=@domain.Execute,
        at_ms~,
        expected_revision=2L,
      ),
    ),
    (
      "attempt-start-command",
      @client.start_attempt_command("cmd-start-1", 3L, id="attempt-2"),
      @domain.StartAttempt(
        id=@domain.AttemptId("attempt-2"),
        at_ms~,
        expected_revision=3L,
      ),
    ),
    (
      "attempt-finish-command",
      @client.finish_attempt_command(
        "cmd-finish-1",
        4L,
        id="attempt-2",
        outcome=@client.Succeeded,
      ),
      @domain.FinishAttempt(
        id=@domain.AttemptId("attempt-2"),
        outcome=@domain.Succeeded,
        at_ms~,
        expected_revision=4L,
      ),
    ),
  ]
  for (name, built, typed) in cases {
    let raw = fixture_text(directory, name)
    let wire = match @protocol.decode_client_frame(raw) {
      Ok(Command(command)) => command
      _ => fail("Invalid canonical client command fixture: " + name)
    }
    assert_eq(wire, built)
    assert_eq(@protocol.decode_board_command(wire, at_ms), Ok(typed))
    let encoded = @protocol.encode_client_frame(Command(wire))
    assert_eq(@json.parse(encoded), @json.parse(raw))
    assert_eq(@protocol.decode_client_frame(encoded), Ok(Command(wire)))
  }
}
