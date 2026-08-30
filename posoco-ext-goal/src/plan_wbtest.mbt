///|
/// Tests for GoalPlan parsing, normalization, and rendering (src/plan.mbt).

///|
/// Build goal_update_plan tool arguments from (title, status) pairs.
fn plan_args(items : Array[(String, String)]) -> Json {
  let item_json : Array[Json] = []
  for pair in items {
    let (title, status) = pair
    item_json.push(
      Json::object(
        Map::from_array([
          ("title", Json::string(title)),
          ("status", Json::string(status)),
        ]),
      ),
    )
  }
  Json::object(Map::from_array([("items", Json::array(item_json))]))
}

///|
test "plan_from_tool_args_happy_path" {
  match
    GoalPlan::from_tool_args(
      plan_args([("write tests", "in_progress"), ("ship release", "pending")]),
    ) {
    Ok(plan) => {
      assert_eq(plan.items.length(), 2)
      assert_eq(plan.items[0].title, "write tests")
      assert_eq(plan.items[0].status, InProgress)
      assert_eq(plan.items[1].title, "ship release")
      assert_eq(plan.items[1].status, Pending)
    }
    Err(reason) => fail("expected Ok, got: \{reason}")
  }
}

///|
test "plan_from_tool_args_rejects_non_object" {
  match GoalPlan::from_tool_args(Json::array([])) {
    Err(reason) => inspect(reason, content="arguments must be a JSON object")
    Ok(_) => fail("expected Err for non-object arguments")
  }
}

///|
test "plan_from_tool_args_requires_items" {
  match GoalPlan::from_tool_args(Json::object(Map::from_array([]))) {
    Err(reason) => inspect(reason, content="arguments are missing \"items\"")
    Ok(_) => fail("expected Err for missing items")
  }
}

///|
test "plan_from_tool_args_rejects_non_array_items" {
  let args = Json::object(Map::from_array([("items", Json::string("nope"))]))
  match GoalPlan::from_tool_args(args) {
    Err(reason) => inspect(reason, content="\"items\" must be an array")
    Ok(_) => fail("expected Err for non-array items")
  }
}

///|
test "plan_from_tool_args_rejects_empty_items" {
  match GoalPlan::from_tool_args(plan_args([])) {
    Err(reason) =>
      inspect(reason, content="plan must contain at least one item")
    Ok(_) => fail("expected Err for empty items")
  }
}

///|
test "plan_from_tool_args_rejects_non_object_item" {
  let args = Json::object(
    Map::from_array([("items", Json::array([Json::string("just a string")]))]),
  )
  match GoalPlan::from_tool_args(args) {
    Err(reason) =>
      inspect(reason, content="each plan item must be a JSON object")
    Ok(_) => fail("expected Err for non-object item")
  }
}

///|
test "plan_from_tool_args_requires_title" {
  let args = Json::object(
    Map::from_array([
      (
        "items",
        Json::array([
          Json::object(Map::from_array([("status", Json::string("pending"))])),
        ]),
      ),
    ]),
  )
  match GoalPlan::from_tool_args(args) {
    Err(reason) => inspect(reason, content="plan item is missing \"title\"")
    Ok(_) => fail("expected Err for missing title")
  }
}

///|
test "plan_from_tool_args_requires_string_title" {
  let bad_title = Json::object(
    Map::from_array([
      (
        "items",
        Json::array([
          Json::object(
            Map::from_array([
              ("title", Json::number(1.0)),
              ("status", Json::string("pending")),
            ]),
          ),
        ]),
      ),
    ]),
  )
  match GoalPlan::from_tool_args(bad_title) {
    Err(reason) =>
      inspect(reason, content="plan item field \"title\" must be a string")
    Ok(_) => fail("expected Err for non-string title")
  }
}

///|
test "plan_from_tool_args_requires_status" {
  let missing = Json::object(
    Map::from_array([
      (
        "items",
        Json::array([
          Json::object(Map::from_array([("title", Json::string("no status"))])),
        ]),
      ),
    ]),
  )
  match GoalPlan::from_tool_args(missing) {
    Err(reason) => inspect(reason, content="plan item is missing \"status\"")
    Ok(_) => fail("expected Err for missing status")
  }
  let non_string = Json::object(
    Map::from_array([
      (
        "items",
        Json::array([
          Json::object(
            Map::from_array([
              ("title", Json::string("bad status")),
              ("status", Json::number(2.0)),
            ]),
          ),
        ]),
      ),
    ]),
  )
  match GoalPlan::from_tool_args(non_string) {
    Err(reason) =>
      inspect(reason, content="plan item field \"status\" must be a string")
    Ok(_) => fail("expected Err for non-string status")
  }
}

///|
test "plan_from_tool_args_rejects_unknown_status" {
  match GoalPlan::from_tool_args(plan_args([("do thing", "cancelled")])) {
    Err(reason) =>
      inspect(
        reason,
        content="unknown status \"cancelled\" for plan item \"do thing\"",
      )
    Ok(_) => fail("expected Err for unknown status")
  }
}

///|
test "plan_normalize_demotes_extra_in_progress" {
  let plan = GoalPlan::{
    items: [
      GoalPlanItem::{ title: "first", status: InProgress, },
      GoalPlanItem::{ title: "second", status: InProgress, },
      GoalPlanItem::{ title: "third", status: Pending, },
    ],
  }
  let normalized = GoalPlan::normalize(plan)
  assert_eq(normalized.items[0].title, "first")
  assert_eq(normalized.items[0].status, InProgress)
  assert_eq(normalized.items[1].title, "second")
  assert_eq(normalized.items[1].status, Pending)
  assert_eq(normalized.items[2].status, Pending)
  // Pure: the original plan is untouched.
  assert_eq(plan.items[1].status, InProgress)
}

///|
test "plan_render_checklist" {
  let plan = GoalPlan::{
    items: [
      GoalPlanItem::{ title: "done thing", status: Done, },
      GoalPlanItem::{ title: "active thing", status: InProgress, },
      GoalPlanItem::{ title: "later thing", status: Pending, },
    ],
  }
  inspect(
    GoalPlan::render(plan),
    content="- [x] done thing\n- [ ] active thing (in progress)\n- [ ] later thing",
  )
  inspect(
    GoalPlan::render(GoalPlan::empty()),
    content="(no plan yet — decompose the goal)",
  )
}

///|
test "plan_progress_line" {
  let plan = GoalPlan::{
    items: [
      GoalPlanItem::{ title: "a", status: Done, },
      GoalPlanItem::{ title: "b", status: Done, },
      GoalPlanItem::{ title: "c", status: InProgress, },
      GoalPlanItem::{ title: "d", status: Pending, },
      GoalPlanItem::{ title: "e", status: Pending, },
    ],
  }
  inspect(GoalPlan::progress_line(plan), content="plan: 2/5 done")
  inspect(GoalPlan::progress_line(GoalPlan::empty()), content="plan: 0/0 done")
}

///|
test "plan_next_step_prefers_in_progress" {
  let plan = GoalPlan::{
    items: [
      GoalPlanItem::{ title: "queued", status: Pending, },
      GoalPlanItem::{ title: "active", status: InProgress, },
      GoalPlanItem::{ title: "later", status: Pending, },
    ],
  }
  match GoalPlan::next_step(plan) {
    Some(title) => inspect(title, content="active")
    None => fail("expected the InProgress title")
  }
}

///|
test "plan_next_step_falls_back_to_first_pending" {
  let plan = GoalPlan::{
    items: [
      GoalPlanItem::{ title: "finished", status: Done, },
      GoalPlanItem::{ title: "first queued", status: Pending, },
      GoalPlanItem::{ title: "second queued", status: Pending, },
    ],
  }
  match GoalPlan::next_step(plan) {
    Some(title) => inspect(title, content="first queued")
    None => fail("expected the first Pending title")
  }
}

///|
test "plan_next_step_none_when_all_done" {
  let plan = GoalPlan::{
    items: [
      GoalPlanItem::{ title: "finished", status: Done, },
      GoalPlanItem::{ title: "also finished", status: Done, },
    ],
  }
  match GoalPlan::next_step(plan) {
    Some(title) => fail("expected None, got \{title}")
    None => ()
  }
}

///|
test "plan_fingerprint_stable_and_sensitive" {
  let before = GoalPlan::{
    items: [
      GoalPlanItem::{ title: "write", status: Pending, },
      GoalPlanItem::{ title: "ship", status: Done, },
    ],
  }
  let after = GoalPlan::{
    items: [
      GoalPlanItem::{ title: "write", status: InProgress, },
      GoalPlanItem::{ title: "ship", status: Done, },
    ],
  }
  inspect(GoalPlan::fingerprint(before), content="write:pending|ship:done")
  inspect(GoalPlan::fingerprint(after), content="write:in_progress|ship:done")
  assert_true(GoalPlan::fingerprint(before) != GoalPlan::fingerprint(after))
  assert_eq(GoalPlan::fingerprint(before), GoalPlan::fingerprint(before))
  inspect(GoalPlan::fingerprint(GoalPlan::empty()), content="")
}

///|
test "plan_status_show" {
  inspect("\{Pending}", content="pending")
  inspect("\{InProgress}", content="in_progress")
  inspect("\{Done}", content="done")
}
