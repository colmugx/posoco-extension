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
    (@client.Cancelled, "cancelled"),
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
    { "dependencies": Array(items), .. } => items[0] = "mutated-outgoing-frame"
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
test "delete command emits only the task id" {
  let command = @client.delete_task_command("cmd-delete", 10L, id="task-1")
  assert_eq(command.command_id, "cmd-delete")
  assert_eq(command.expected_revision, 10L)
  assert_eq(command.name, "board.task.delete")
  assert_eq(command.args, { "id": "task-1" })
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

///|
test "attempt enum encodings are the canonical kind and outcome vocabulary" {
  let kinds : Array[(@client.ClientAttemptKind, String)] = [
    (@client.Discuss, "discuss"),
    (@client.Execute, "execute"),
    (@client.Review, "review"),
  ]
  for (value, wire) in kinds {
    assert_eq(value.to_wire(), wire)
  }
  let outcomes : Array[(@client.ClientAttemptOutcome, String)] = [
    (@client.Succeeded, "succeeded"),
    (@client.Failed, "failed"),
    (@client.Cancelled, "cancelled"),
    (@client.Interrupted, "interrupted"),
  ]
  for (value, wire) in outcomes {
    assert_eq(value.to_wire(), wire)
  }
}

///|
test "queue attempt command emits explicit id task and kind with revision" {
  let command = @client.queue_attempt_command(
    "cmd-queue",
    2L,
    id="attempt-next",
    task_id="task-1",
    kind=@client.Execute,
  )
  assert_eq(command.command_id, "cmd-queue")
  assert_eq(command.expected_revision, 2L)
  assert_eq(command.name, "board.attempt.queue")
  assert_eq(command.args, {
    "id": "attempt-next",
    "task_id": "task-1",
    "kind": "execute",
  })
  assert_eq(
    @protocol.decode_client_frame(
      @protocol.encode_client_frame(@protocol.Command(command)),
    ),
    Ok(@protocol.Command(command)),
  )
}

///|
test "start attempt command emits only the attempt id" {
  let command = @client.start_attempt_command("cmd-start", 3L, id="attempt-1")
  assert_eq(command.command_id, "cmd-start")
  assert_eq(command.expected_revision, 3L)
  assert_eq(command.name, "board.attempt.start")
  assert_eq(command.args, { "id": "attempt-1" })
  assert_eq(
    @protocol.decode_client_frame(
      @protocol.encode_client_frame(@protocol.Command(command)),
    ),
    Ok(@protocol.Command(command)),
  )
}

///|
test "finish attempt command requires an explicit terminal outcome" {
  let outcomes : Array[(@client.ClientAttemptOutcome, String)] = [
    (@client.Succeeded, "succeeded"),
    (@client.Failed, "failed"),
    (@client.Cancelled, "cancelled"),
    (@client.Interrupted, "interrupted"),
  ]
  for (outcome, wire) in outcomes {
    let command = @client.finish_attempt_command(
      "cmd-finish",
      4L,
      id="attempt-1",
      outcome~,
    )
    assert_eq(command.command_id, "cmd-finish")
    assert_eq(command.expected_revision, 4L)
    assert_eq(command.name, "board.attempt.finish")
    assert_eq(command.args, { "id": "attempt-1", "outcome": wire })
    assert_eq(
      @protocol.decode_client_frame(
        @protocol.encode_client_frame(@protocol.Command(command)),
      ),
      Ok(@protocol.Command(command)),
    )
  }
}

///|
test "recordable review decision vocabulary has no pending wire case" {
  let decisions : Array[(@client.ClientRecordableReviewDecision, String)] = [
    (@client.Approved, "approved"),
    (@client.ChangesRequested, "changes_requested"),
  ]
  for (value, wire) in decisions {
    assert_eq(value.to_wire(), wire)
  }
}

///|
test "record review command emits only the attempt id and terminal decision" {
  let decisions : Array[(@client.ClientRecordableReviewDecision, String)] = [
    (@client.Approved, "approved"),
    (@client.ChangesRequested, "changes_requested"),
  ]
  for (decision, wire) in decisions {
    let command = @client.record_review_command(
      "cmd-review",
      5L,
      id="attempt-1",
      decision~,
    )
    assert_eq(command.command_id, "cmd-review")
    assert_eq(command.expected_revision, 5L)
    assert_eq(command.name, "board.review.record")
    assert_eq(command.args, { "id": "attempt-1", "decision": wire })
    assert_eq(
      @protocol.decode_client_frame(
        @protocol.encode_client_frame(@protocol.Command(command)),
      ),
      Ok(@protocol.Command(command)),
    )
  }
}

///|
test "set model command pins and clears through explicit null" {
  let pinned = @client.set_task_model_command(
    "cmd-model",
    6L,
    id="ticket-1",
    model=Some(
      @client.ClientModelSelection::ClientModelSelection(
        slot="openai/gpt-5.2",
        effort=Some("high"),
      ),
    ),
  )
  assert_eq(pinned.name, "board.task.set_model")
  assert_eq(pinned.args, {
    "id": "ticket-1",
    "model": { "slot": "openai/gpt-5.2", "effort": "high" },
  })
  let cleared = @client.set_task_model_command(
    "cmd-clear",
    7L,
    id="ticket-1",
    model=None,
  )
  assert_eq(cleared.args, { "id": "ticket-1", "model": Json::null() })
  assert_eq(
    @protocol.decode_client_frame(
      @protocol.encode_client_frame(@protocol.Command(cleared)),
    ),
    Ok(@protocol.Command(cleared)),
  )
}

///|
fn report_command_fixture() -> @client.ClientReviewReport {
  @client.ClientReviewReport::ClientReviewReport(
    outcome="Ticket carries a curated review handoff.",
    summary="Adds the report write command.",
    changes=["Client can set and clear a report."],
    verification=[
      @client.ClientReviewEvidence::ClientReviewEvidence(
        kind=@client.ClientReviewEvidenceKind::Command,
        label="moon test src/client",
        result=@client.ClientReviewEvidenceResult::Passed,
        detail="",
      ),
      @client.ClientReviewEvidence::ClientReviewEvidence(
        kind=@client.ClientReviewEvidenceKind::Manual,
        label="restart drill",
        result=@client.ClientReviewEvidenceResult::NotRun,
        detail="no host",
      ),
    ],
    risks=["Reports are worker-derived."],
    notes=[],
    open_questions=["Does a retry replace it?"],
    artifacts=[
      @client.ClientReviewArtifact::ClientReviewArtifact(
        kind=@client.ClientReviewArtifactKind::File,
        label="commands.mbt",
        uri_or_digest="src/client/commands.mbt",
      ),
    ],
  )
}

///|
test "set review report command sends a full report or an explicit null" {
  let report = report_command_fixture()
  let set = @client.set_task_review_report_command(
    "cmd-report",
    8L,
    id="ticket-1",
    review=Some(report),
  )
  assert_eq(set.command_id, "cmd-report")
  assert_eq(set.expected_revision, 8L)
  assert_eq(set.name, "board.task.set_review_report")
  assert_eq(set.args, {
    "id": "ticket-1",
    "review": {
      "outcome": "Ticket carries a curated review handoff.",
      "summary": "Adds the report write command.",
      "changes": ["Client can set and clear a report."],
      "verification": [
        {
          "kind": "command",
          "label": "moon test src/client",
          "result": "passed",
          "detail": "",
        },
        {
          "kind": "manual",
          "label": "restart drill",
          "result": "not_run",
          "detail": "no host",
        },
      ],
      "risks": ["Reports are worker-derived."],
      "notes": [],
      "open_questions": ["Does a retry replace it?"],
      "artifacts": [
        {
          "kind": "file",
          "label": "commands.mbt",
          "uri_or_digest": "src/client/commands.mbt",
        },
      ],
    },
  })
  // The encoder never aliases the caller's arrays.
  report.changes.push("late")
  report.artifacts.clear()
  match set.args {
    Json::Object(fields) =>
      match fields["review"] {
        Json::Object(review) => {
          assert_eq(
            review["changes"],
            Json::array([Json::string("Client can set and clear a report.")]),
          )
          assert_eq(
            review["artifacts"],
            Json::array([
              Json::object({
                "kind": Json::string("file"),
                "label": Json::string("commands.mbt"),
                "uri_or_digest": Json::string("src/client/commands.mbt"),
              }),
            ]),
          )
        }
        _ => fail("expected review object")
      }
    _ => fail("expected args object")
  }
  let cleared = @client.set_task_review_report_command(
    "cmd-clear-report",
    9L,
    id="ticket-1",
    review=None,
  )
  assert_eq(cleared.args, { "id": "ticket-1", "review": Json::null() })
  for command in [set, cleared] {
    assert_eq(
      @protocol.decode_client_frame(
        @protocol.encode_client_frame(@protocol.Command(command)),
      ),
      Ok(@protocol.Command(command)),
    )
  }
}

///|
test "review evidence artifact and result vocabulary has one wire spelling" {
  let evidence_kinds : Array[(@client.ClientReviewEvidenceKind, String)] = [
    (@client.Command, "command"),
    (@client.Test, "test"),
    (@client.Manual, "manual"),
    (@client.Artifact, "artifact"),
  ]
  for (kind, wire) in evidence_kinds {
    assert_eq(kind.to_wire(), wire)
  }
  let results : Array[(@client.ClientReviewEvidenceResult, String)] = [
    (@client.Passed, "passed"),
    (@client.Failed, "failed"),
    (@client.NotRun, "not_run"),
    (@client.Unknown, "unknown"),
  ]
  for (result, wire) in results {
    assert_eq(result.to_wire(), wire)
  }
  let artifact_kinds : Array[(@client.ClientReviewArtifactKind, String)] = [
    (@client.File, "file"),
    (@client.Diff, "diff"),
    (@client.Log, "log"),
    (@client.Screenshot, "screenshot"),
    (@client.Url, "url"),
  ]
  for (kind, wire) in artifact_kinds {
    assert_eq(kind.to_wire(), wire)
  }
}

///|
test "request changes command sends the attempt id and the reviewer body" {
  let command = @client.request_changes_command(
    "cmd-changes",
    6L,
    attempt_id="attempt-1",
    feedback="  Add the missing regression test.  ",
  )
  assert_eq(command.command_id, "cmd-changes")
  assert_eq(command.expected_revision, 6L)
  assert_eq(command.name, "board.task.request_changes")
  // Trimming and the length cap belong to the durable server, so the body is
  // forwarded verbatim and no timestamp or revision can enter the args.
  assert_eq(command.args, {
    "id": "attempt-1",
    "feedback": "  Add the missing regression test.  ",
  })
  assert_eq(
    @protocol.decode_client_frame(
      @protocol.encode_client_frame(@protocol.Command(command)),
    ),
    Ok(@protocol.Command(command)),
  )
  assert_eq(
    @protocol.decode_board_command(command, 1234L),
    Ok(
      @domain.RequestChanges(
        id=@domain.AttemptId("attempt-1"),
        feedback="  Add the missing regression test.  ",
        at_ms=1234L,
        expected_revision=6L,
      ),
    ),
  )
}
