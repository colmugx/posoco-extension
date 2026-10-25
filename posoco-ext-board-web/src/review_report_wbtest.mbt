///|
/// One verification record exactly as the wire carries it.
fn report_evidence_json(
  kind : String,
  label : String,
  result : String,
  detail : String,
) -> Json {
  {
    "kind": Json(kind),
    "label": Json(label),
    "result": Json(result),
    "detail": Json(detail),
  }
}

///|
fn report_artifact_json(
  kind : String,
  label : String,
  reference : String,
) -> Json {
  { "kind": Json(kind), "label": Json(label), "uri_or_digest": Json(reference) }
}

///|
/// A complete report projection: every field the client requires, with the
/// nested evidence and artifacts the caller supplies.
fn report_json(
  evidence~ : Array[Json] = [],
  artifacts~ : Array[Json] = [],
) -> Json {
  {
    "outcome": "Adds a durable work report read model.",
    "summary": "The reviewer reads the curated report before deciding.",
    "changes": ["Task wire carries review.", "Legacy stays null."],
    "verification": Json(evidence),
    "risks": ["A report is optional in the wire contract."],
    "notes": ["Raw run activity stays in the Activity dialog."],
    "open_questions": ["Does a retry replace the report?"],
    "artifacts": Json(artifacts),
  }
}

///|
/// The inspected task with the caller's stage and report projection; a
/// `Json::null()` report is the "nothing recorded" case.
fn report_task_json(stage : String, review : Json) -> Json {
  {
    "id": "t",
    "title": "Title t",
    "description": "Task details",
    "stage": Json(stage),
    "priority": "high",
    "definition_of_done": [],
    "dependencies": [],
    "created_at_ms": 10,
    "updated_at_ms": 20,
    "ready_since_ms": null,
    "review": review,
  }
}

///|
fn report_model(task : Json, attempts~ : Array[Json] = []) -> Model {
  let replica = @client.BoardReplica::empty()
  guard replica.apply_text(inspector_snapshot([task], attempts~)) is Applied else {
    abort("Invalid work report test snapshot")
  }
  {
    ..Model::empty(true),
    replica,
    connection: Online,
    selected_task: Some("t"),
  }
}

///|
fn report_emit(_msg : Msg) -> @rabbita.Cmd {
  @rabbita.none
}

///|
test "work report renders decision first with nested evidence and artifacts" {
  let model = report_model(
    report_task_json(
      "review",
      report_json(
        evidence=[
          report_evidence_json(
            "command", "moon check src", "passed", "0 errors",
          ),
          report_evidence_json("test", "moon test src", "failed", "2 failing"),
          report_evidence_json("manual", "Keyboard-only pass", "not_run", ""),
          report_evidence_json(
            "artifact", "Bundle size", "unknown", "Not measured",
          ),
        ],
        artifacts=[
          report_artifact_json("diff", "Report diff", "sha256:6f1c"),
          report_artifact_json(
            "url", "Preview build", "https://example.test/p/17",
          ),
        ],
      ),
    ),
  )
  let task = inspector_task(model).unwrap()
  let report = task.review.unwrap()
  // The outcome is the headline, not a stage label or the summary.
  assert_eq(report.outcome, "Adds a durable work report read model.")
  assert_eq(
    review_outcome_text(report),
    "Adds a durable work report read model.",
  )
  assert_eq(
    report.summary,
    "The reviewer reads the curated report before deciding.",
  )
  assert_eq(report.changes, ["Task wire carries review.", "Legacy stays null."])
  assert_eq(report.risks.length(), 1)
  assert_eq(report.notes.length(), 1)
  assert_eq(report.open_questions.length(), 1)
  // Nested evidence keeps record order, one distinct tone per result.
  let rows : Array[ReviewEvidenceRow] = report.verification.map(
    review_evidence_row,
  )
  assert_eq(rows.length(), 4)
  assert_eq(rows.map(row => row.tone), [
    "passed", "failed", "not_run", "unknown",
  ])
  assert_eq(rows.map(row => row.result), [
    "Passed", "Failed", "Not run", "Unknown",
  ])
  assert_eq(rows.map(row => row.kind), ["Command", "Test", "Manual", "Artifact"])
  assert_eq(rows.map(row => row.label), [
    "moon check src", "moon test src", "Keyboard-only pass", "Bundle size",
  ])
  // A check with no detail renders no detail line instead of a blank one.
  assert_eq(rows.map(row => row.detail), [
    "0 errors", "2 failing", "", "Not measured",
  ])
  // Nested artifacts keep kind, label and the URI or digest only.
  let artifacts : Array[ReviewArtifactRow] = report.artifacts.map(
    review_artifact_row,
  )
  assert_eq(artifacts.map(artifact => artifact.kind), ["Diff", "URL"])
  assert_eq(artifacts.map(artifact => artifact.label), [
    "Report diff", "Preview build",
  ])
  assert_eq(artifacts.map(artifact => artifact.reference), [
    "sha256:6f1c", "https://example.test/p/17",
  ])
  // The decision-first report renders, and stops rendering without a record.
  assert_true(review_report_block(task) != @html.nothing)
  let bare = inspector_task(
    report_model(report_task_json("review", Json::null())),
  ).unwrap()
  assert_true(bare.review is None)
  assert_true(review_report_block(bare) == @html.nothing)
}

///|
test "review without a work report shows a blocking note and no report" {
  let model = report_model(report_task_json("review", Json::null()))
  let task = inspector_task(model).unwrap()
  assert_true(task.review is None)
  // Review is the only stage that expects a report it does not have.
  assert_true(review_report_missing(task))
  assert_eq(
    review_missing_report_note(),
    "No work report recorded yet. Ask the worker to record one before you decide.",
  )
  // Nothing is fabricated: the report section is absent, not empty.
  assert_true(review_report_block(task) == @html.nothing)
  // The Review section itself still renders, so the note and the existing
  // Approve / Request changes controls stay reachable behind one predicate.
  assert_true(review_block(model, task, report_emit) != @html.nothing)
  // A recorded report clears the note; a stage that is not Review never
  // claims one is missing.
  assert_false(
    review_report_missing(
      inspector_task(report_model(report_task_json("review", report_json()))).unwrap(),
    ),
  )
  let done = inspector_task(
    report_model(report_task_json("done", Json::null())),
  ).unwrap()
  assert_false(review_report_missing(done))
  assert_true(review_report_block(done) == @html.nothing)
  assert_true(review_block(model, done, report_emit) != @html.nothing)
}

///|
test "recorded work report leaves the review decision controls untouched" {
  // The same running Review attempt, with and without a curated report: the
  // report informs the decision, it never replaces or blocks it.
  let with_report = report_model(report_task_json("review", report_json()), attempts=[
    review_attempt_json("running", "pending"),
  ])
  let without_report = report_model(report_task_json("review", Json::null()), attempts=[
    review_attempt_json("running", "pending"),
  ])
  assert_eq(review_decision_controls().map(review_decision_label), ["Approve"])
  assert_eq(review_decision_controls().map(decision => decision.to_wire()), [
    "approved",
  ])
  for model in [with_report, without_report] {
    let task = inspector_task(model).unwrap()
    // The report renders only where it exists; the Review section holding
    // the controls renders either way.
    assert_eq(
      review_report_block(task) != @html.nothing,
      task.review is Some(_),
    )
    assert_true(review_block(model, task, report_emit) != @html.nothing)
    // One click still fills the draft and opens the confirmation.
    let (decided, command) = update(
      model,
      ReviewDecide("a", "approved"),
      test_emit,
      counting_env(),
    )
    assert_true(
      decided.review_draft
      is Some({ task_id: "t", attempt_id: "a", decision: Some(Approved), }),
    )
    assert_true(decided.confirm is Some(ConfirmReview))
    debug_inspect(command, content="[]")
  }
}
