///|
fn wbtest_model_catalog() -> ModelCatalog {
  {
    selectable: true,
    kind: "ext_llm",
    models: [
      {
        id: "openai/gpt-5.2",
        label: "GPT-5.2",
        provider: "openai",
        model: "gpt-5.2",
        efforts: ["low", "high"],
        default_effort: Some("high"),
        context_window: Some(400000L),
        capabilities: ["image_in"],
      },
      {
        id: "anthropic/opus",
        label: "Opus",
        provider: "anthropic",
        model: "opus",
        efforts: [],
        default_effort: None,
        context_window: None,
        capabilities: [],
      },
    ],
  }
}

///|
fn wbtest_ticket_state_text(model_selection : String) -> String {
  let catalog = if model_selection == "" {
    ""
  } else {
    ",\"model_selection\":" + model_selection
  }
  "{\"type\":\"ticket_state\",\"state\":{\"questions\":[],\"runs\":[]\{catalog}}}"
}

///|
fn wbtest_json_field(value : Json, name : String) -> Json? {
  match value {
    Object(fields) => fields.get(name)
    _ => None
  }
}

///|
fn wbtest_ticket_model(
  model_selection : ModelCatalog?,
  runs : Array[TicketRun],
) -> Model {
  apply_ticket_state(Model::empty(true), {
    project: "",
    team: None,
    questions: [],
    runs,
    progress: [],
    live: None,
    model_selection,
  })
}

///|
fn wbtest_running_run(task_id : String) -> TicketRun {
  {
    task_id,
    session_id: "s1",
    phase: "work",
    role: "rd",
    status: "running",
    error: None,
    result: None,
    steps: 0,
    current_tool: None,
    preview: "",
    reasoning: "",
    activities: [],
  }
}

///|
test "ticket state decodes the model catalog projection" {
  let text = "{\"type\":\"ticket_state\",\"state\":{\"questions\":[],\"runs\":[],\"model_selection\":{\"selectable\":true,\"kind\":\"ext_llm\",\"future\":1,\"models\":[{\"id\":\"openai/gpt-5.2\",\"label\":\"GPT-5.2\",\"provider\":\"openai\",\"model\":\"gpt-5.2\",\"efforts\":[\"low\",\"high\",7],\"default_effort\":\"high\",\"context_window\":400000,\"capabilities\":[\"image_in\"],\"unknown\":true},{\"label\":\"missing id\"},{\"id\":\"\"}]}}}"
  match ticket_frame(text) {
    Some(TicketSnapshot(state)) =>
      match state.model_selection {
        Some(catalog) => {
          assert_true(catalog.selectable)
          assert_eq(catalog.kind, "ext_llm")
          // Unknown fields and entries without a stable slot id are skipped.
          assert_eq(catalog.models.length(), 1)
          let option = catalog.models[0]
          assert_eq(option.id, "openai/gpt-5.2")
          assert_eq(option.label, "GPT-5.2")
          assert_eq(option.provider, "openai")
          assert_eq(option.model, "gpt-5.2")
          assert_eq(option.efforts, ["low", "high"])
          assert_eq(option.default_effort, Some("high"))
          assert_eq(option.context_window, Some(400000L))
          assert_eq(option.capabilities, ["image_in"])
        }
        None => fail("expected a decoded model catalog")
      }
    _ => fail("expected a ticket state frame")
  }
}

///|
test "absent null and malformed model catalogs stay read-only" {
  // Absent, explicit null, a wrongly typed selectable flag and a non-object
  // projection all mean the host offers no picker, never a crash.
  for json in ["", "null", "{\"selectable\":\"yes\",\"models\":[]}", "[]", "42"] {
    match ticket_frame(wbtest_ticket_state_text(json)) {
      Some(TicketSnapshot(state)) => {
        let model = apply_ticket_state(Model::empty(true), state)
        let catalog = ticket_model_catalog(model)
        assert_false(catalog.selectable)
        assert_eq(catalog.models.length(), 0)
      }
      _ => fail("expected a ticket state frame")
    }
  }
}

///|
test "a ticket frame that omits the catalog keeps the last known one" {
  let text = "{\"type\":\"ticket_state\",\"state\":{\"questions\":[],\"runs\":[],\"model_selection\":{\"selectable\":true,\"kind\":\"ext_llm\",\"models\":[{\"id\":\"openai/gpt-5.2\"}]}}}"
  let initial = match ticket_frame(text) {
    Some(TicketSnapshot(state)) => apply_ticket_state(Model::empty(true), state)
    _ => fail("expected a ticket state frame")
  }
  assert_true(ticket_model_catalog(initial).selectable)
  // A `ticket_result` may omit runtime projection; it must not blank the
  // picker the user is looking at.
  let outcome = apply_ticket_state(initial, TicketState::empty())
  assert_true(ticket_model_catalog(outcome).selectable)
  assert_eq(ticket_model_catalog(outcome).models.length(), 1)
  // An explicit non-selectable projection does replace the retained catalog.
  let disabled = apply_ticket_state(outcome, {
    project: "",
    team: None,
    questions: [],
    runs: [],
    progress: [],
    live: None,
    model_selection: Some({ selectable: false, kind: "magpie", models: [], }),
  })
  assert_false(ticket_model_catalog(disabled).selectable)
  assert_eq(ticket_model_catalog(disabled).kind, "magpie")
}

///|
test "model chip names inheritance and never fakes a pinned slot" {
  let catalog = wbtest_model_catalog()
  assert_eq(model_chip_label(None), "Inherit")
  assert_eq(model_chip_tone(catalog, None), "is-inherit")
  assert_true(model_chip_title(catalog, None).contains("follows"))
  let pinned = @client.ClientModelSelection::ClientModelSelection(
    slot="openai/gpt-5.2",
    effort=Some("high"),
  )
  assert_eq(model_chip_label(Some(pinned)), "openai/gpt-5.2 · high")
  assert_eq(model_chip_tone(catalog, Some(pinned)), "is-pinned")
  let default_effort = @client.ClientModelSelection::ClientModelSelection(
    slot="anthropic/opus",
  )
  assert_eq(model_chip_label(Some(default_effort)), "anthropic/opus")
  assert_eq(model_chip_tone(catalog, Some(default_effort)), "is-pinned")
  // A pinned slot the catalog no longer offers warns rather than pretending
  // it is still selectable.
  let gone = @client.ClientModelSelection::ClientModelSelection(
    slot="openai/gpt-4",
  )
  assert_eq(model_chip_tone(catalog, Some(gone)), "is-warn")
  assert_true(
    model_chip_title(catalog, Some(gone)).contains("no longer offers"),
  )
  // With no projection at all there is nothing to compare the pin against.
  assert_eq(
    model_chip_tone(ModelCatalog::unavailable(), Some(gone)),
    "is-pinned",
  )
}

///|
test "model selector starts with inherit and keeps stable slot values" {
  let catalog = wbtest_model_catalog()
  let options = model_slot_options(catalog, None)
  assert_eq(options.length(), 3)
  assert_eq(options[0].value, "")
  assert_eq(options[0].label, "Inherit current")
  assert_true(options[0].selected)
  assert_eq(options[1].value, "openai/gpt-5.2")
  assert_eq(options[1].label, "GPT-5.2 · openai")
  assert_true(options[1].title.contains("400k context"))
  assert_false(options[1].selected)
  assert_eq(options[2].value, "anthropic/opus")
  assert_eq(options[2].label, "Opus · anthropic")
  let pinned = @client.ClientModelSelection::ClientModelSelection(
    slot="openai/gpt-5.2",
    effort=Some("high"),
  )
  let pinned_options = model_slot_options(catalog, Some(pinned))
  assert_false(pinned_options[0].selected)
  assert_true(pinned_options[1].selected)
}

///|
test "pinned slot missing from the catalog stays visible and disabled" {
  let catalog = wbtest_model_catalog()
  let gone = @client.ClientModelSelection::ClientModelSelection(
    slot="openai/gpt-4",
  )
  let options = model_slot_options(catalog, Some(gone))
  assert_eq(options.length(), 4)
  assert_false(options[0].selected)
  let missing = options[3]
  assert_eq(missing.value, "openai/gpt-4")
  assert_true(missing.selected)
  assert_true(missing.disabled)
  assert_true(missing.label.contains("unavailable"))
}

///|
test "effort selector offers auto default plus advertised efforts" {
  let option = wbtest_model_catalog().models[0]
  let auto = model_effort_options(option, None)
  assert_eq(auto.length(), 3)
  assert_eq(auto[0].value, "")
  assert_eq(auto[0].label, "Auto/default")
  assert_true(auto[0].selected)
  assert_true(auto[0].title.contains("high"))
  assert_false(auto[1].selected)
  let high = model_effort_options(option, Some("high"))
  assert_eq(high[1].value, "low")
  assert_false(high[1].selected)
  assert_true(high[2].selected)
  let gone = model_effort_options(option, Some("medium"))
  assert_eq(gone.length(), 4)
  assert_true(gone[3].selected)
  assert_true(gone[3].disabled)
  assert_true(gone[3].label.contains("unavailable"))
}

///|
test "select values resolve to the wire model choice" {
  let inherit_choice : ModelChoice? = model_choice_from_slot("")
  assert_true(inherit_choice is None)
  guard model_choice_from_slot("openai/gpt-5.2") is Some(bare) else {
    fail("expected a bare slot choice")
  }
  assert_eq(bare.slot, "openai/gpt-5.2")
  assert_true(bare.effort is None)
  let defaulted = model_choice_with_effort("openai/gpt-5.2", "")
  assert_eq(defaulted.slot, "openai/gpt-5.2")
  assert_true(defaulted.effort is None)
  let high = model_choice_with_effort("openai/gpt-5.2", "high")
  assert_eq(high.slot, "openai/gpt-5.2")
  assert_true(high.effort == Some("high"))
}

///|
test "ticket set model command args pin the stable slot and explicit inherit" {
  let inherit_args = ticket_set_model_args("t1", None)
  assert_eq(
    wbtest_json_field(inherit_args, "task_id"),
    Some(Json::string("t1")),
  )
  assert_eq(wbtest_json_field(inherit_args, "model"), Some(Json::null()))
  let pinned = ticket_set_model_args(
    "t1",
    Some({ slot: "openai/gpt-5.2", effort: Some("high"), }),
  )
  match wbtest_json_field(pinned, "model") {
    Some(Object(fields)) => {
      assert_eq(fields.get("slot"), Some(Json::string("openai/gpt-5.2")))
      assert_eq(fields.get("effort"), Some(Json::string("high")))
    }
    _ => fail("expected a model object")
  }
  // Effort "Auto/default" travels as an explicit null, not an empty string.
  let auto = ticket_set_model_args(
    "t1",
    Some({ slot: "openai/gpt-5.2", effort: None, }),
  )
  match wbtest_json_field(auto, "model") {
    Some(Object(fields)) => assert_eq(fields.get("effort"), Some(Json::null()))
    _ => fail("expected a model object")
  }
}

///|
test "set model is disabled while the ticket runs or the catalog is read-only" {
  let choice : ModelChoice? = Some({ slot: "openai/gpt-5.2", effort: None, })
  let busy = wbtest_ticket_model(Some(wbtest_model_catalog()), [
    wbtest_running_run("t1"),
  ])
  let (blocked, _) = update(
    busy,
    TicketSetModel("t1", choice),
    test_emit,
    test_env(),
  )
  assert_true(blocked == busy)
  // A run on another ticket does not block this ticket.
  let other = wbtest_ticket_model(Some(wbtest_model_catalog()), [
    wbtest_running_run("t2"),
  ])
  let (sent, _) = update(
    other,
    TicketSetModel("t1", choice),
    test_emit,
    test_env(),
  )
  assert_true(sent.ticket_sending)
  // No optimistic model state: only the sending gate changes.
  assert_true(sent.tickets == other.tickets)
  // A read-only catalog never sends a choice.
  let read_only = wbtest_ticket_model(
    Some({ selectable: false, kind: "magpie", models: [], }),
    [],
  )
  let (ignored, _) = update(
    read_only,
    TicketSetModel("t1", choice),
    test_emit,
    test_env(),
  )
  assert_false(ignored.ticket_sending)
  assert_true(ignored == read_only)
  // The ticket runtime must be advertised before any model command is sent.
  let (unavailable, _) = update(
    Model::empty(true),
    TicketSetModel("t1", choice),
    test_emit,
    test_env(),
  )
  assert_false(unavailable.ticket_sending)
}

///|
test "model picker stays available for the next run" {
  let ready = wbtest_ticket_model(Some(wbtest_model_catalog()), [])
  assert_eq(model_picker_blocked(ready, "t1"), None)
  let running = wbtest_ticket_model(Some(wbtest_model_catalog()), [
    wbtest_running_run("t1"),
  ])
  // A running worker keeps its composed model; the picker changes the NEXT run.
  assert_eq(model_picker_blocked(running, "t1"), None)
  match model_picker_blocked({ ..ready, ticket_sending: true, }, "t1") {
    Some(text) => assert_true(text.to_lower().contains("wait"))
    None => fail("an in-flight command must explain why the picker is locked")
  }
  match model_picker_blocked(Model::empty(true), "t1") {
    Some(text) => assert_true(text.contains("unavailable"))
    None => fail("an unavailable runtime must explain why the picker is locked")
  }
  assert_true(model_unavailable_note(None).contains("inherits"))
  assert_true(
    model_unavailable_note(
      Some(
        @client.ClientModelSelection::ClientModelSelection(
          slot="openai/gpt-5.2",
        ),
      ),
    ).contains("read-only"),
  )
}
