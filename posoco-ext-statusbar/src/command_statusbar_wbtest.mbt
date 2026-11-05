///|
/// `/statusbar` listing command tests. The status side publishes
/// `@kit_events.StatusChanged` ops on a real `@posoco.EventSystem`, so the
/// command is exercised against the same protocol path publishers use.

///|
async test "listing reports every registered segment with its owner" {
  let (bar, ui, channel) = new_composed_bar()
  channel.register(
    source="posoco_ext_plan",
    segment="plan",
    label="Plan",
    priority=10,
  )
  channel.register(
    source="posoco_ext_llm",
    segment="model",
    label="Model",
    priority=20,
    value="deepseek-v4-pro",
  )
  let renders_before = ui.renders.length()
  let outcome = bar.invoke("statusbar", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      inspect(
        feedback,
        content=(
          #|statusbar segments: 2
          #|plan | posoco_ext_plan | p10 | — | —
          #|model | posoco_ext_llm | p20 | — | deepseek-v4-pro
        ),
      )
      match structured {
        Some(json) =>
          json_inspect(json, content=[
            {
              "segment": "plan",
              "owner": "posoco_ext_plan",
              "priority": 10,
              "label": "Plan",
            },
            {
              "segment": "model",
              "owner": "posoco_ext_llm",
              "priority": 20,
              "label": "Model",
              "value": "deepseek-v4-pro",
            },
          ])
        None => fail("expected a structured listing payload")
      }
    }
    _ => fail("expected success")
  }
  // The listing is read-only: no extra render.
  assert_eq(ui.renders.length(), renders_before)
}

///|
async test "empty bar lists a zero count" {
  let (bar, _ui, _channel) = new_composed_bar()
  let outcome = bar.invoke("statusbar", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      inspect(
        feedback,
        content=(
          #|statusbar segments: 0
        ),
      )
    _ => fail("expected success")
  }
}

///|
async test "non-empty arguments are rejected" {
  let (bar, _ui, _channel) = new_composed_bar()
  try
    bar.invoke(
      "statusbar",
      Json::object(Map::from_array([("_positional", Json::string("model"))])),
    )
  catch {
    @posoco.CommandError::InvalidArgs(reason~) =>
      inspect(
        reason,
        content=(
          #|/statusbar takes no arguments
        ),
      )
    _ => fail("expected InvalidArgs")
  } noraise {
    _ => fail("expected InvalidArgs")
  }
}
