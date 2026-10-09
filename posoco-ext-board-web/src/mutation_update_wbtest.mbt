///|
test "create submit uses the live revision and one pending correlation record" {
  let env = counting_env()
  let model = seeded_online("t", "ready")
  let (opened, _) = update(model, CreateOpened, test_emit, env)
  let (drafted, _) = update(opened, TitleChanged("Ship it"), test_emit, env)
  let (submitted, _) = update(drafted, SubmitRequested, test_emit, env)
  assert_true(
    submitted.pending
    is Some({ command_id: "cmd-uuid-1", kind: PendingCreate, revision: 1L, }),
  )
  // Max one pending: a further submit while one is in flight is a no-op.
  let (again, _) = update(submitted, SubmitRequested, test_emit, env)
  assert_true(again == submitted)
  // An authoritative event advances the replica; the pending record and the
  // absence of optimistic cards are untouched.
  let (evented, _) = update(
    submitted,
    SocketEvent(0, Message(task_event_text("t", "running", 1, 2))),
    test_emit,
    env,
  )
  assert_eq(evented.replica.revision(), 2L)
  assert_eq(evented.replica.tasks().length(), 1)
  assert_true(evented.pending == submitted.pending)
  assert_true(evented.editor == submitted.editor)
}

///|
test "submissions always stamp the live replica revision" {
  let env = counting_env()
  let model = seeded_online("t", "ready")
  let (opened, _) = update(model, CreateOpened, test_emit, env)
  let (drafted, _) = update(opened, TitleChanged("Ship it"), test_emit, env)
  let (submitted, _) = update(drafted, SubmitRequested, test_emit, env)
  let (accepted, _) = update(
    submitted,
    SocketEvent(
      0,
      Message(command_result_text("cmd-uuid-1", true, None, Some(1L))),
    ),
    test_emit,
    env,
  )
  assert_true(accepted.pending is None)
  let (evented, _) = update(
    accepted,
    SocketEvent(0, Message(task_event_text("t", "running", 1, 2))),
    test_emit,
    env,
  )
  assert_eq(evented.replica.revision(), 2L)
  let (reopened, _) = update(evented, CreateOpened, test_emit, env)
  let (redrafted, _) = update(reopened, TitleChanged("Again"), test_emit, env)
  let (resubmitted, _) = update(redrafted, SubmitRequested, test_emit, env)
  assert_true(
    resubmitted.pending
    is Some({ command_id: "cmd-uuid-2", kind: PendingCreate, revision: 2L, }),
  )
}

///|
test "submit is guarded without baseline offline empty title or free slot" {
  let env = test_env()
  // Connecting without a snapshot: the board is unknown, not writable.
  let without_baseline = Model::empty(true)
  let (opened, _) = update(without_baseline, CreateOpened, test_emit, env)
  let (drafted, _) = update(opened, TitleChanged("Ship it"), test_emit, env)
  let (blocked, _) = update(drafted, SubmitRequested, test_emit, env)
  assert_true(blocked.pending is None)
  assert_true(blocked.notice is None)
  // Offline shell without a token never submits.
  let offline = Model::empty(false)
  let (offline_open, _) = update(offline, CreateOpened, test_emit, env)
  let (offline_draft, _) = update(
    offline_open,
    TitleChanged("Ship it"),
    test_emit,
    env,
  )
  let (offline_submit, _) = update(
    offline_draft,
    SubmitRequested,
    test_emit,
    env,
  )
  let (offline_move, _) = update(
    offline_submit,
    MoveRequested("t", Ready),
    test_emit,
    env,
  )
  assert_true(offline_move.pending is None)
  // Whitespace-only titles never submit.
  let online = seeded_online("t", "ready")
  let (blank_open, _) = update(online, CreateOpened, test_emit, env)
  let (blank, _) = update(blank_open, TitleChanged("   "), test_emit, env)
  let (blank_submit, _) = update(blank, SubmitRequested, test_emit, env)
  assert_true(blank_submit.pending is None)
  // Max one pending command: the free slot gates moves as well.
  let (first_open, _) = update(online, CreateOpened, test_emit, env)
  let (first_draft, _) = update(
    first_open,
    TitleChanged("Ship it"),
    test_emit,
    env,
  )
  let (first, _) = update(first_draft, SubmitRequested, test_emit, env)
  let (second, _) = update(first, MoveRequested("t", Running), test_emit, env)
  assert_true(second == first)
}

///|
test "accepted correlated result clears pending closes the editor and never mutates the replica" {
  let env = test_env()
  let model = seeded_online("t", "ready")
  let (opened, _) = update(model, CreateOpened, test_emit, env)
  let (drafted, _) = update(opened, TitleChanged("Ship it"), test_emit, env)
  let (submitted, _) = update(drafted, SubmitRequested, test_emit, env)
  let replica_before = submitted.replica
  let (settled, _) = update(
    submitted,
    SocketEvent(
      0,
      Message(command_result_text("cmd-uuid-1", true, None, Some(1L))),
    ),
    test_emit,
    env,
  )
  assert_true(settled.pending is None)
  assert_true(settled.editor is None)
  match settled.notice {
    Some(value) => {
      assert_true(value.severity is Success)
      assert_false(value.text.contains("board.task.create"))
      assert_false(value.text.contains("cmd-uuid-1"))
    }
    None => fail("expected success notice")
  }
  // Results never project replica state.
  assert_true(settled.replica == replica_before)
  assert_eq(settled.replica.tasks().length(), 1)
  assert_true(settled.connection is Online)
}

///|
test "accepted result with a foreign revision still saves but resynchronizes" {
  let env = test_env()
  let model = seeded_online("t", "ready")
  let (opened, _) = update(model, CreateOpened, test_emit, env)
  let (drafted, _) = update(opened, TitleChanged("Ship it"), test_emit, env)
  let (submitted, _) = update(drafted, SubmitRequested, test_emit, env)
  let (settled, _) = update(
    submitted,
    SocketEvent(
      0,
      Message(command_result_text("cmd-uuid-1", true, None, Some(9L))),
    ),
    test_emit,
    env,
  )
  assert_true(settled.pending is None)
  assert_true(settled.editor is None)
  match settled.notice {
    Some(value) => {
      assert_true(value.severity is Success)
      assert_true(value.text.contains("Refreshing authoritative board state."))
    }
    None => fail("expected saved-and-refresh notice")
  }
  assert_false(settled.replica.has_snapshot())
  assert_eq(settled.replica.tasks().length(), 0)
  assert_true(settled.connection is Reconnecting)
  assert_true(settled.retry_pending)
  // Reconnect continues from Hello only; the original command is never sent
  // again.
  let (retried, _) = update(settled, Retry(0), test_emit, env)
  let (resumed, _) = update(retried, SocketEvent(1, Opened), test_emit, env)
  match @protocol.decode_client_frame(hello_payload(resumed.replica)) {
    Ok(Hello(hello)) => {
      assert_false(hello.has_board_snapshot)
      assert_eq(hello.last_seq, 0L)
    }
    _ => fail("expected Hello only")
  }
  assert_true(resumed.pending is None)
}

///|
test "rejected result keeps the draft and baseline without rollback" {
  let env = test_env()
  let model = seeded_online("t", "ready")
  let (edit, _) = update(model, EditOpened("t"), test_emit, env)
  let (drafted, _) = update(edit, TitleChanged("Changed"), test_emit, env)
  let (submitted, _) = update(drafted, SubmitRequested, test_emit, env)
  assert_true(
    submitted.pending
    is Some(
      {
        command_id: "cmd-uuid-1",
        kind: PendingEdit(task_id="t"),
        revision: 1L,
      }
    ),
  )
  let (settled, _) = update(
    submitted,
    SocketEvent(
      0,
      Message(
        command_result_text(
          "cmd-uuid-1",
          false,
          Some("invalid_transition"),
          Some(1L),
        ),
      ),
    ),
    test_emit,
    env,
  )
  assert_true(settled.pending is None)
  match settled.editor {
    Some(editor) => {
      assert_true(editor.mode is EditMode(task_id="t"))
      assert_eq(editor.title, "Changed")
    }
    None => fail("the draft must survive rejection")
  }
  assert_true(settled.replica.has_snapshot())
  assert_eq(settled.replica.tasks().length(), 1)
  assert_true(settled.connection is Online)
  match settled.notice {
    Some(value) => {
      assert_true(value.severity is Error)
      assert_eq(
        value.text,
        "The board does not allow this change from the task's current stage.",
      )
    }
    None => fail("expected mapped notice")
  }
}

///|
test "revision conflict forces snapshot resync without resend" {
  let env = test_env()
  let model = seeded_online("t", "ready")
  let (edit, _) = update(model, EditOpened("t"), test_emit, env)
  let (drafted, _) = update(edit, TitleChanged("Changed"), test_emit, env)
  let (submitted, _) = update(drafted, SubmitRequested, test_emit, env)
  let (settled, _) = update(
    submitted,
    SocketEvent(
      0,
      Message(
        command_result_text(
          "cmd-uuid-1",
          false,
          Some("revision_conflict"),
          Some(9L),
        ),
      ),
    ),
    test_emit,
    env,
  )
  assert_true(settled.pending is None)
  match settled.editor {
    Some(_) => ()
    None => fail("the draft must survive a conflict")
  }
  assert_false(settled.replica.has_snapshot())
  assert_eq(settled.replica.tasks().length(), 0)
  assert_true(settled.connection is Reconnecting)
  assert_true(settled.retry_pending)
  match settled.notice {
    Some(value) => {
      assert_true(value.severity is Warning)
      assert_false(value.text.contains("revision_conflict"))
    }
    None => fail("expected explanatory notice")
  }
  // The reconnect socket sends ONLY Hello: no original command is replayed.
  let (retried, _) = update(settled, Retry(0), test_emit, env)
  let (resumed, _) = update(retried, SocketEvent(1, Opened), test_emit, env)
  match @protocol.decode_client_frame(hello_payload(resumed.replica)) {
    Ok(Hello(hello)) => {
      assert_false(hello.has_board_snapshot)
      assert_eq(hello.last_seq, 0L)
    }
    _ => fail("expected Hello only")
  }
  assert_true(resumed.pending is None)
}

///|
test "persistence failure at the same revision keeps the baseline" {
  let env = test_env()
  let model = seeded_online("t", "ready")
  let (edit, _) = update(model, EditOpened("t"), test_emit, env)
  let (drafted, _) = update(edit, TitleChanged("Changed"), test_emit, env)
  let (submitted, _) = update(drafted, SubmitRequested, test_emit, env)
  let (settled, _) = update(
    submitted,
    SocketEvent(
      0,
      Message(
        command_result_text(
          "cmd-uuid-1",
          false,
          Some("persistence_failed"),
          Some(1L),
        ),
      ),
    ),
    test_emit,
    env,
  )
  assert_true(settled.pending is None)
  assert_true(settled.replica.has_snapshot())
  assert_eq(settled.replica.tasks().length(), 1)
  assert_true(settled.connection is Online)
  assert_true(
    settled.notice
    is Some(
      {
        severity: Error,
        text: "The board could not save this change. Nothing was retried.",
      }
    ),
  )
}

///|
test "durability uncertainty retains a matching baseline and resyncs a stale one" {
  let env = counting_env()
  let model = seeded_online("t", "ready")
  let (edit, _) = update(model, EditOpened("t"), test_emit, env)
  let (drafted, _) = update(edit, TitleChanged("Changed"), test_emit, env)
  let (submitted, _) = update(drafted, SubmitRequested, test_emit, env)
  // Matching revision: the event state is retained with a warning.
  let (uncertain, _) = update(
    submitted,
    SocketEvent(
      0,
      Message(
        command_result_text(
          "cmd-uuid-1",
          false,
          Some("durability_uncertain"),
          Some(1L),
        ),
      ),
    ),
    test_emit,
    env,
  )
  assert_true(uncertain.pending is None)
  assert_true(uncertain.replica.has_snapshot())
  assert_true(uncertain.connection is Online)
  assert_true(uncertain.editor is Some(_))
  match uncertain.notice {
    Some(value) => assert_true(value.severity is Warning)
    None => fail("expected durability warning")
  }
  // Stale revision: force a snapshot, keep the draft.
  let (edit_again, _) = update(uncertain, EditOpened("t"), test_emit, env)
  assert_true(edit_again.editor is Some(_))
  let (redrafted, _) = update(edit_again, TitleChanged("Again"), test_emit, env)
  let (resubmitted, _) = update(redrafted, SubmitRequested, test_emit, env)
  let (stale, _) = update(
    resubmitted,
    SocketEvent(
      0,
      Message(
        command_result_text(
          "cmd-uuid-2",
          false,
          Some("durability_uncertain"),
          Some(5L),
        ),
      ),
    ),
    test_emit,
    env,
  )
  assert_true(stale.pending is None)
  assert_false(stale.replica.has_snapshot())
  assert_true(stale.connection is Reconnecting)
  assert_true(stale.editor is Some(_))
}

///|
test "foreign results are ignored entirely" {
  let env = test_env()
  let online = seeded_online("t", "ready")
  // Without a pending command a result changes nothing at all.
  let (ignored, _) = update(
    online,
    SocketEvent(
      0,
      Message(command_result_text("cmd-uuid-1", true, None, Some(1L))),
    ),
    test_emit,
    env,
  )
  assert_true(ignored == online)
  // With a pending command only the matching correlation id settles.
  let (opened, _) = update(online, CreateOpened, test_emit, env)
  let (drafted, _) = update(opened, TitleChanged("Ship it"), test_emit, env)
  let (submitted, _) = update(drafted, SubmitRequested, test_emit, env)
  let (foreign, _) = update(
    submitted,
    SocketEvent(
      0,
      Message(command_result_text("cmd-other", true, None, Some(1L))),
    ),
    test_emit,
    env,
  )
  assert_true(foreign == submitted)
}

///|
test "missing browser uuid rejects submission without sending" {
  let env = missing_uuid_env()
  let model = seeded_online("t", "ready")
  let (opened, _) = update(model, CreateOpened, test_emit, env)
  let (drafted, _) = update(opened, TitleChanged("Ship it"), test_emit, env)
  let (rejected, _) = update(drafted, SubmitRequested, test_emit, env)
  assert_true(rejected.pending is None)
  assert_true(rejected.editor == drafted.editor)
  match rejected.notice {
    Some(value) => {
      assert_true(value.severity is Error)
      assert_eq(
        value.text,
        "This browser cannot generate the identifiers required to submit changes.",
      )
    }
    None => fail("expected identifier notice")
  }
  // Moves are equally rejected.
  let (moved, _) = update(rejected, MoveRequested("t", Running), test_emit, env)
  assert_true(moved.pending is None)
}

///|
test "send failures correlate generation and command id before clearing pending" {
  let env = counting_env()
  let model = seeded_online("t", "ready")
  let (opened, _) = update(model, CreateOpened, test_emit, env)
  let (drafted, _) = update(opened, TitleChanged("Ship it"), test_emit, env)
  let (submitted, _) = update(drafted, SubmitRequested, test_emit, env)
  // A foreign command id never clears the pending record.
  let (foreign, _) = update(
    submitted,
    SendFailed(0, "cmd-other"),
    test_emit,
    env,
  )
  assert_true(foreign == submitted)
  // A stale generation never clears the pending record.
  let (stale, _) = update(
    submitted,
    SendFailed(7, "cmd-uuid-1"),
    test_emit,
    env,
  )
  assert_true(stale == submitted)
  // The correlated failure empties the replica, keeps the draft and reuses
  // the existing reconnect scheduler.
  let (failed, _) = update(
    submitted,
    SendFailed(0, "cmd-uuid-1"),
    test_emit,
    env,
  )
  assert_true(failed.pending is None)
  assert_false(failed.replica.has_snapshot())
  assert_true(failed.editor is Some(_))
  assert_true(failed.connection is Reconnecting)
  assert_true(failed.retry_pending)
  match failed.notice {
    Some(value) => assert_true(value.severity is Warning)
    None => fail("expected warning notice")
  }
  // After a fresh snapshot a new command pends under a new generation; an
  // old send failure cannot clear it.
  let (retried, _) = update(failed, Retry(0), test_emit, env)
  let (resumed, _) = update(retried, SocketEvent(1, Opened), test_emit, env)
  let (snapshotted, _) = update(
    resumed,
    SocketEvent(
      1,
      Message(snapshot_text(Json::array([carded_task_json("t", "ready")]), 1)),
    ),
    test_emit,
    env,
  )
  let (reopened, _) = update(snapshotted, CreateOpened, test_emit, env)
  let (redrafted, _) = update(reopened, TitleChanged("Second"), test_emit, env)
  let (resubmitted, _) = update(redrafted, SubmitRequested, test_emit, env)
  assert_true(
    resubmitted.pending
    is Some({ command_id: "cmd-uuid-2", kind: PendingCreate, revision: 1L, }),
  )
  let (late, _) = update(
    resubmitted,
    SendFailed(0, "cmd-uuid-2"),
    test_emit,
    env,
  )
  assert_true(late == resubmitted)
}

///|
test "disconnect with pending drops the baseline and reconnects without resending" {
  let env = test_env()
  let model = seeded_online("t", "ready")
  let (edit, _) = update(model, EditOpened("t"), test_emit, env)
  let (drafted, _) = update(edit, TitleChanged("Changed"), test_emit, env)
  let (submitted, _) = update(drafted, SubmitRequested, test_emit, env)
  let (closed, _) = update(submitted, SocketEvent(0, Errored), test_emit, env)
  assert_true(closed.pending is None)
  assert_false(closed.replica.has_snapshot())
  assert_true(closed.editor is Some(_))
  assert_true(closed.connection is Reconnecting)
  assert_true(closed.retry_pending)
  let (retried, _) = update(closed, Retry(0), test_emit, env)
  let (resumed, _) = update(retried, SocketEvent(1, Opened), test_emit, env)
  // Reconnect sends ONLY Hello: the unconfirmed command is never resent.
  match @protocol.decode_client_frame(hello_payload(resumed.replica)) {
    Ok(Hello(hello)) => {
      assert_false(hello.has_board_snapshot)
      assert_eq(hello.last_seq, 0L)
    }
    _ => fail("expected Hello only")
  }
  assert_true(resumed.pending is None)
}

///|
test "ordinary disconnect preserves the baseline for replay" {
  let online = seeded_online("t", "ready")
  let (closed, _) = update(
    online,
    SocketEvent(0, Errored),
    test_emit,
    test_env(),
  )
  assert_true(closed.replica.has_snapshot())
  assert_eq(closed.replica.tasks().length(), 1)
  assert_true(closed.connection is Reconnecting)
  assert_true(closed.notice is None)
  let (retried, _) = update(closed, Retry(0), test_emit, test_env())
  let (resumed, _) = update(
    retried,
    SocketEvent(1, Opened),
    test_emit,
    test_env(),
  )
  match @protocol.decode_client_frame(hello_payload(resumed.replica)) {
    Ok(Hello(hello)) => assert_true(hello.has_board_snapshot)
    _ => fail("expected baseline-aware Hello")
  }
}

///|
test "resync and terminal errors never leave a stale pending record" {
  let env = counting_env()
  // A pending command plus a malformed frame resynchronizes without a
  // stale pending record and keeps the draft.
  let model = seeded_online("t", "ready")
  let (opened, _) = update(model, CreateOpened, test_emit, env)
  let (drafted, _) = update(opened, TitleChanged("Ship it"), test_emit, env)
  let (submitted, _) = update(drafted, SubmitRequested, test_emit, env)
  let (desynced, _) = update(
    submitted,
    SocketEvent(0, Message("{")),
    test_emit,
    env,
  )
  assert_true(desynced.pending is None)
  assert_false(desynced.replica.has_snapshot())
  assert_true(desynced.editor is Some(_))
  assert_true(desynced.connection is Reconnecting)
  // A pending command plus a terminal protocol error stops retries, keeps
  // the draft and maps no protocol detail into the notice.
  let other = seeded_online("t", "ready")
  let (other_open, _) = update(other, CreateOpened, test_emit, env)
  let (other_draft, _) = update(
    other_open,
    TitleChanged("Ship it"),
    test_emit,
    env,
  )
  let (other_submitted, _) = update(
    other_draft,
    SubmitRequested,
    test_emit,
    env,
  )
  let (terminal, _) = update(
    other_submitted,
    SocketEvent(
      0,
      Message(
        @protocol.encode_server_frame(
          Error(code="unsupported_version", message="must never appear in UI"),
        ),
      ),
    ),
    test_emit,
    env,
  )
  assert_true(terminal.pending is None)
  assert_true(terminal.connection is ProtocolError(_))
  assert_false(terminal.retry_pending)
  assert_true(terminal.editor is Some(_))
  match terminal.notice {
    Some(value) => {
      assert_false(value.text.contains("unsupported_version"))
      assert_false(value.text.contains("must never"))
    }
    None => fail("expected warning notice")
  }
}

///|
test "editor lifecycle prefills drafts and closes on missing authoritative targets" {
  let env = test_env()
  let model = seeded_online("t", "ready")
  // A create draft starts blank at the default priority.
  let (opened, _) = update(model, CreateOpened, test_emit, env)
  match opened.editor {
    Some(editor) => {
      assert_true(editor.mode is CreateMode)
      assert_eq(editor.title, "")
      assert_eq(editor.description, "")
      assert_true(editor.priority is Normal)
      assert_eq(editor.definition_of_done, "")
    }
    None => fail("expected create draft")
  }
  // Only one editor exists at a time.
  let (ignored, _) = update(opened, EditOpened("t"), test_emit, env)
  assert_true(ignored == opened)
  let (cancelled, _) = update(opened, EditorCancelled, test_emit, env)
  assert_true(cancelled.editor is None)
  // Edit prefill comes from the authoritative record.
  let (edit, _) = update(cancelled, EditOpened("t"), test_emit, env)
  match edit.editor {
    Some(editor) => {
      assert_true(editor.mode is EditMode(task_id="t"))
      assert_eq(editor.title, "Task t")
      assert_eq(editor.description, "Read-only task")
      assert_true(editor.priority is Normal)
      assert_eq(editor.definition_of_done, "")
    }
    None => fail("expected prefilled draft")
  }
  // Draft edits apply only while an editor is open.
  let (closed_draft, _) = update(edit, EditorCancelled, test_emit, env)
  let (untouched, _) = update(
    closed_draft,
    TitleChanged("no-op"),
    test_emit,
    env,
  )
  assert_true(untouched == closed_draft)
  // Opening a missing target shows a notice and opens nothing.
  let (missing, _) = update(model, EditOpened("absent"), test_emit, env)
  assert_true(missing.editor is None)
  assert_true(
    missing.notice
    is Some({ severity: Error, text: "That task is no longer on the board.", }),
  )
  // A snapshot without the target closes the draft with the same notice.
  let (edit_again, _) = update(model, EditOpened("t"), test_emit, env)
  let (replaced, _) = update(
    edit_again,
    SocketEvent(
      0,
      Message(
        snapshot_text(Json::array([carded_task_json("other", "ready")]), 2),
      ),
    ),
    test_emit,
    env,
  )
  assert_true(replaced.editor is None)
  assert_true(
    replaced.notice
    is Some({ severity: Error, text: "That task is no longer on the board.", }),
  )
  // An empty reconciliation baseline never closes the draft on its own.
  let (edit_once_more, _) = update(
    replaced,
    EditOpened("other"),
    test_emit,
    env,
  )
  let (desynced, _) = update(
    edit_once_more,
    SocketEvent(0, Message("{")),
    test_emit,
    env,
  )
  assert_false(desynced.replica.has_snapshot())
  assert_true(desynced.editor is Some(_))
}

///|
test "move submissions stamp kind stage and live revision" {
  let env = counting_env()
  let model = seeded_online("t", "ready")
  let (moved, _) = update(model, MoveRequested("t", Running), test_emit, env)
  assert_true(
    moved.pending
    is Some(
      {
        command_id: "cmd-uuid-1",
        kind: PendingMove(task_id="t", to=Running),
        revision: 1L,
      }
    ),
  )
  assert_true(moved.editor is None)
  // While the move is pending nothing else may submit.
  let (blocked, _) = update(moved, MoveRequested("t", Refining), test_emit, env)
  assert_true(blocked == moved)
}
