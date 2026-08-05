///|
fn items_args(items : Array[String]) -> Json {
  Json::object(
    Map::from_array([
      ("items", Json::array(items.map(item => Json::string(item)))),
    ]),
  )
}

///|
async test "query reports the current layout without re-rendering" {
  let (bar, ui) = new_bar()
  let outcome = bar.invoke("statusbar", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      inspect(
        feedback,
        content=(
          #|statusbar segments: model | effort | turn | tools | tok | session | lat
        ),
      )
      match structured {
        Some(json) =>
          json_inspect(json, content={
            "items": [
              "model", "effort", "turn", "tools", "tok", "session", "lat",
            ],
            "available": [
              "model", "effort", "turn", "tools", "tok", "session", "lat",
            ],
            "defaults": [
              "model", "effort", "turn", "tools", "tok", "session", "lat",
            ],
          })
        None => fail("expected a structured layout payload")
      }
    }
    _ => fail("expected success")
  }
  inspect(ui.renders.length(), content="0")
}

///|
async test "set items reorders the rendered segments" {
  let (bar, ui) = new_bar()
  bar.set_model("deepseek-v4-pro", effort=Some("high"))
  let outcome = bar.invoke("statusbar", items_args(["tok", "model"]))
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      inspect(
        feedback,
        content=(
          #|statusbar segments: tok | model
        ),
      )
    _ => fail("expected success")
  }
  debug_inspect(
    key_value_pairs(ui.last()),
    content=(
      #|[("tok", "0↑ 0↓"), ("model", "deepseek-v4-pro")]
    ),
  )
}

///|
async test "unknown segment id fails with the available list" {
  let (bar, _ui) = new_bar()
  let outcome = bar.invoke("statusbar", items_args(["bogus"]))
  match outcome {
    @posoco.CommandOutcome::Failure(reason~) =>
      inspect(
        reason,
        content=(
          #|CommandError::InvalidArgs(unknown statusbar segment 'bogus'; available: model, effort, turn, tools, tok, session, lat)
        ),
      )
    _ => fail("expected failure")
  }
}

///|
async test "reset restores the default layout" {
  let (bar, _ui) = new_bar()
  let _ = bar.invoke("statusbar", items_args(["tok"]))
  let outcome = bar.invoke(
    "statusbar",
    Json::object(Map::from_array([("reset", Json::boolean(true))])),
  )
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      inspect(
        feedback,
        content=(
          #|statusbar reset: model | effort | turn | tools | tok | session | lat
        ),
      )
    _ => fail("expected success")
  }
  debug_inspect(
    bar.items(),
    content=(
      #|["model", "effort", "turn", "tools", "tok", "session", "lat"]
    ),
  )
}

///|
async test "positional comma string sets items" {
  let (bar, _ui) = new_bar()
  let outcome = bar.invoke(
    "statusbar",
    Json::object(Map::from_array([("_positional", Json::string("model, tok"))])),
  )
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      inspect(
        feedback,
        content=(
          #|statusbar segments: model | tok
        ),
      )
    _ => fail("expected success")
  }
  debug_inspect(
    bar.items(),
    content=(
      #|["model", "tok"]
    ),
  )
}

///|
async test "empty items hides the bar" {
  let (bar, ui) = new_bar()
  let outcome = bar.invoke("statusbar", items_args([]))
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      inspect(
        feedback,
        content=(
          #|statusbar hidden (no segments)
        ),
      )
    _ => fail("expected success")
  }
  debug_inspect(
    key_value_pairs(ui.last()),
    content=(
      #|[]
    ),
  )
}

///|
async test "unknown command id raises NotFound" {
  let (bar, _ui) = new_bar()
  try bar.invoke("bogus", Json::null()) catch {
    @posoco.CommandError::NotFound(id) =>
      inspect(
        id,
        content=(
          #|bogus
        ),
      )
    _ => fail("expected NotFound")
  } noraise {
    _ => fail("expected NotFound")
  }
}
