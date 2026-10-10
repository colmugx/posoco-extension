///|
test "review recovery revalidates preserved intent against Pending Approved ChangesRequested and terminal snapshots without replay" {
  for
    (status, decision, eligible) in [
      ("running", "pending", true),
      ("running", "approved", false),
      ("running", "changes_requested", false),
      ("interrupted", "pending", false),
    ] {
    let pending = submitted_review()
    let (lost, _) = update(
      pending,
      SocketEvent(0, Errored),
      test_emit,
      test_env(),
    )
    assert_true(lost.pending is None)
    assert_false(lost.replica.has_snapshot())
    assert_true(inspector_attempts(lost).is_empty())
    assert_true(lost.review_draft == pending.review_draft)
    let (retry, _) = update(lost, Retry(0), test_emit, test_env())
    let (opened, sent) = update(
      retry,
      SocketEvent(1, Opened),
      test_emit,
      test_env(),
    )
    let hello = hello_payload(opened.replica)
    assert_true(
      @protocol.decode_client_frame(hello)
      is Ok(Hello({ last_seq: 0L, has_board_snapshot: false, .. })),
    )
    assert_eq(
      Repr(sent).to_string(),
      Repr(
        @websocket.send("board", Text(hello), failed=_ => {
          test_emit(TransportFailed(1))
        }),
      ).to_string(),
    )
    let (recovered, cmd) = update(
      opened,
      SocketEvent(
        1,
        Message(
          inspector_snapshot(
            [dependency_task_json("t", [])],
            attempts=[review_attempt_json(status, decision)],
            revision=4L,
          ),
        ),
      ),
      test_emit,
      test_env(),
    )
    debug_inspect(cmd, content="[]")
    assert_true(recovered.pending is None)
    assert_true(recovered.review_draft == pending.review_draft)
    assert_eq(
      review_submit_allowed(recovered, recovered.review_draft.unwrap()),
      eligible,
    )
    assert_eq(inspector_attempts(recovered).length(), 1)
    assert_true(
      recovered.replica.tasks()[0].stage == pending.replica.tasks()[0].stage,
    )
  }
}

///|
test "external review choices preserve the user's draft but prevent overwrite and a missing parent closes it" {
  for decision in ["approved", "changes_requested"] {
    let draft = chosen_review("approved")
    let (externally, cmd) = update(
      draft,
      SocketEvent(0, Message(review_recorded_event(decision~, review=decision))),
      test_emit,
      test_env(),
    )
    debug_inspect(cmd, content="[]")
    assert_true(externally.review_draft == draft.review_draft)
    assert_false(
      review_submit_allowed(externally, externally.review_draft.unwrap()),
    )
    assert_eq(
      attempt_status_label(
        attempt_by_id(externally.replica, "a").unwrap().status,
      ),
      "Running",
    )
    assert_eq(
      attempt_by_id(externally.replica, "a").unwrap().finished_at_ms,
      None,
    )
    let (blocked, sent) = update(
      externally,
      ReviewSubmitted,
      test_emit,
      test_env(),
    )
    assert_true(blocked == externally)
    debug_inspect(sent, content="[]")
  }
  let draft = chosen_review("changes_requested")
  let (removed, _) = update(
    draft,
    SocketEvent(0, Message(inspector_snapshot([], revision=2L))),
    test_emit,
    test_env(),
  )
  assert_true(removed.review_draft is None)
  assert_true(removed.selected_task is None)
  assert_true(removed.notice is Some({ severity: Warning, .. }))
}

///|
test "review action labels describe intent separately from projected decision labels" {
  assert_eq(review_decision_label(@client.Approved), "Approve")
  assert_eq(review_decision_label(@client.ChangesRequested), "Request changes")
  assert_eq(review_label(@client.Approved), "Review approved")
  assert_eq(review_label(@client.ChangesRequested), "Review changes requested")
  let draft = opened_review(test_env())
  assert_true(draft.review_draft.unwrap().decision is None)
  assert_false(review_submit_allowed(draft, draft.review_draft.unwrap()))
}
