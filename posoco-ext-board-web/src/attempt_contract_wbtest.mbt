///|
test "queue submits each canonical kind without inserting a local attempt" {
  for kind in ["discuss", "execute", "review"] {
    let env = counting_env()
    let opened = opened_queue(env)
    let (chosen, _) = update(opened, AttemptKindChanged(kind), test_emit, env)
    let (pending, sent) = update(chosen, AttemptQueueSubmitted, test_emit, env)
    let expected = @client.queue_attempt_command(
      "cmd-uuid-2",
      chosen.replica.revision(),
      id="attempt-uuid-1",
      task_id="t",
      kind=chosen.attempt_draft.unwrap().kind,
    )
    assert_eq(expected.args, {
      "id": "attempt-uuid-1",
      "task_id": "t",
      "kind": kind.to_json(),
    })
    assert_eq(
      Repr(sent).to_string(),
      Repr(send_command(0, expected, test_emit)).to_string(),
    )
    assert_true(pending.replica == chosen.replica)
    assert_true(pending.pending is Some(_))
  }
}

///|
test "attempt history order is independent of snapshot input order" {
  let replica = @client.BoardReplica::empty()
  assert_true(
    replica.apply_text(
      inspector_snapshot([dependency_task_json("t", [])], attempts=[
        lifecycle_attempt("queued", id="z"),
        lifecycle_attempt("running", id="a"),
      ]),
    )
    is Applied,
  )
  let model = {
    ..Model::empty(true),
    replica,
    connection: Online,
    selected_task: Some("t"),
  }
  assert_eq(inspector_attempts(model).map(attempt => attempt.id), ["a", "z"])
  assert_eq(model.replica.attempts().map(attempt => attempt.id), ["z", "a"])
}
