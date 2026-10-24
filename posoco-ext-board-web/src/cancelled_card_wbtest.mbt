///|
/// A cancelled task is terminal: it is archived like Done and Paused, its
/// card shows no primary action, and it offers no moves. Done keeps its
/// reopen action, so the gate stays specific to Cancelled.
fn cancelled_card_task_json(
  id : String,
  title : String,
  stage : String,
  created_ms : Int32,
) -> Json {
  {
    "id": Json(id),
    "title": Json(title),
    "description": "",
    "stage": Json(stage),
    "priority": "normal",
    "definition_of_done": [],
    "dependencies": [],
    "created_at_ms": Json(created_ms),
    "updated_at_ms": Json(created_ms),
    "ready_since_ms": null,
  }
}

///|
fn cancelled_card_model() -> Model {
  let replica = @client.BoardReplica::empty()
  let applied = replica.apply_snapshot({
    protocol_version: 1,
    last_seq: 0L,
    board_revision: 1L,
    payload: {
      "board": {
        "revision": 1,
        "tasks": [
          cancelled_card_task_json("gone", "Abandoned idea", "cancelled", 10),
          cancelled_card_task_json("closed", "Shipped work", "done", 20),
        ],
        "attempts": [],
      },
      "events": [],
    },
  })
  guard applied is @client.Applied else {
    abort("Invalid cancelled card snapshot")
  }
  { ..Model::empty(true), replica, connection: Online, }
}

///|
test "cancelled card is archived without a primary action or a move" {
  let model = cancelled_card_model()
  let emit : @rabbita.Emit[Msg] = _msg => @rabbita.none
  // Both archive stages count towards the Archive badge.
  assert_eq(archive_count(model), 2)
  assert_eq(archive_lanes().map(stage => ui_stage_label(stage)), [
    "Done", "Paused", "Cancelled",
  ])
  // A cancelled task never occupies a flow column.
  for stage in flow_lanes() {
    assert_eq(
      visible_lane_tasks(model.replica, stage, model.task_filter).length(),
      0,
    )
  }
  let cancelled = visible_lane_tasks(
      model.replica,
      Cancelled,
      model.task_filter,
    )[0]
  assert_eq(cancelled.id, "gone")
  assert_eq(stage_step(cancelled.stage), None)
  assert_false(has_primary_intent(cancelled.stage))
  // The card renders no primary button and the menu offers no move.
  assert_true(
    primary_intent(model, cancelled, emit, disabled=false, class="card-next") ==
    @html.nothing,
  )
  assert_eq(move_suggestions(cancelled.stage).length(), 0)
  assert_eq(card_alternatives(cancelled.stage).length(), 0)
  // The inspector replaces the next action with the terminal note.
  assert_true(detail_next_action(model, cancelled, emit) != @html.nothing)
  assert_eq(cancelled_note(), "Cancelled; kept for history.")
  // Done is untouched: it keeps its reopen action and never offers Cancelled.
  let closed = visible_lane_tasks(model.replica, Done, model.task_filter)[0]
  assert_true(has_primary_intent(closed.stage))
  assert_true(
    primary_intent(model, closed, emit, disabled=false, class="card-next") !=
    @html.nothing,
  )
  assert_false(card_alternatives(closed.stage).contains(Cancelled))
}
