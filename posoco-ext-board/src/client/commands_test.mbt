///|
test "command enum encodings are the canonical priority and stage vocabulary" {
  let priorities : Array[(@client.ClientBoardPriority, String)] = [
    (@client.Low, "low"),
    (@client.Normal, "normal"),
    (@client.High, "high"),
    (@client.Critical, "critical"),
  ]
  for (value, wire) in priorities {
    assert_eq(value.to_wire(), wire)
  }
  let stages : Array[(@client.ClientBoardStage, String)] = [
    (@client.Created, "created"),
    (@client.Refining, "refining"),
    (@client.Ready, "ready"),
    (@client.Running, "running"),
    (@client.Review, "review"),
    (@client.Done, "done"),
    (@client.Suspended, "suspended"),
  ]
  for (value, wire) in stages {
    assert_eq(value.to_wire(), wire)
  }
}

///|
test "create command emits exact args and top level revision correlation" {
  let command = @client.create_task_command(
    "cmd-create",
    42L,
    id="task-created",
    title="Implement board",
    description="Authoritative only",
    priority=@client.High,
    definition_of_done=["Tests pass", "No retries"],
    dependencies=["task-existing"],
  )
  assert_eq(command.command_id, "cmd-create")
  assert_eq(command.expected_revision, 42L)
  assert_eq(command.name, "board.task.create")
  assert_eq(command.args, {
    "id": "task-created",
    "title": "Implement board",
    "description": "Authoritative only",
    "priority": "high",
    "definition_of_done": ["Tests pass", "No retries"],
    "dependencies": ["task-existing"],
  })
  let frame = @protocol.Command(command)
  assert_eq(
    @protocol.decode_client_frame(@protocol.encode_client_frame(frame)),
    Ok(frame),
  )
}

///|
test "update command preserves absence and explicit empty DoD without null" {
  let omitted = @client.update_task_command("cmd-minimal", 7L, id="task-1")
  assert_eq(omitted.args, { "id": "task-1" })
  let full = @client.update_task_command(
    "cmd-update",
    8L,
    id="task-1",
    title="New title",
    description="",
    priority=@client.Critical,
    definition_of_done=[],
  )
  assert_eq(full.command_id, "cmd-update")
  assert_eq(full.expected_revision, 8L)
  assert_eq(full.name, "board.task.update")
  assert_eq(full.args, {
    "id": "task-1",
    "title": "New title",
    "description": "",
    "priority": "critical",
    "definition_of_done": [],
  })
  assert_eq(
    @protocol.decode_client_frame(
      @protocol.encode_client_frame(@protocol.Command(full)),
    ),
    Ok(@protocol.Command(full)),
  )
}

///|
test "set dependencies command replaces the complete detached dependency list" {
  let dependencies = ["task-2", "task-3"]
  let command = @client.set_task_dependencies_command(
    "cmd-deps",
    9L,
    id="task-1",
    dependencies~,
  )
  dependencies[0] = "changed-draft"
  assert_eq(command.command_id, "cmd-deps")
  assert_eq(command.expected_revision, 9L)
  assert_eq(command.name, "board.task.set_dependencies")
  assert_eq(command.args, {
    "id": "task-1",
    "dependencies": ["task-2", "task-3"],
  })
  match command.args {
    { "dependencies": Array(items), .. } =>
      items[0] = "mutated-outgoing-frame"
    _ => fail("dependency command must contain a dependency array")
  }
  assert_eq(dependencies, ["changed-draft", "task-3"])
  assert_eq(
    @protocol.decode_client_frame(
      @protocol.encode_client_frame(@protocol.Command(command)),
    ),
    Ok(@protocol.Command(command)),
  )
}

///|
test "move command emits only id and to and does not validate the server FSM" {
  let command = @client.move_task_command(
    "cmd-move",
    9L,
    id="task-1",
    to=@client.Done,
  )
  assert_eq(command.command_id, "cmd-move")
  assert_eq(command.expected_revision, 9L)
  assert_eq(command.name, "board.task.move")
  assert_eq(command.args, { "id": "task-1", "to": "done" })
  assert_eq(
    @protocol.decode_client_frame(
      @protocol.encode_client_frame(@protocol.Command(command)),
    ),
    Ok(@protocol.Command(command)),
  )
}

///|
test "command array inputs and separate commands never share mutable JSON arrays" {
  let dod = ["Original DoD"]
  let dependencies = ["task-dependency"]
  let create = @client.create_task_command(
    "cmd-1",
    0L,
    id="task-1",
    title="Title",
    description="",
    priority=@client.Normal,
    definition_of_done=dod,
    dependencies~,
  )
  let update = @client.update_task_command(
    "cmd-2",
    1L,
    id="task-1",
    definition_of_done=dod,
  )
  dod[0] = "Changed draft"
  dependencies.push("new dependency")
  assert_eq(create.args, {
    "id": "task-1",
    "title": "Title",
    "description": "",
    "priority": "normal",
    "definition_of_done": ["Original DoD"],
    "dependencies": ["task-dependency"],
  })
  assert_eq(update.args, {
    "id": "task-1",
    "definition_of_done": ["Original DoD"],
  })
  match create.args {
    { "definition_of_done": Array(items), .. } =>
      items[0] = "Mutated outgoing frame"
    _ => fail("create must contain a DoD array")
  }
  assert_eq(update.args, {
    "id": "task-1",
    "definition_of_done": ["Original DoD"],
  })
  assert_eq(dod, ["Changed draft"])
}
