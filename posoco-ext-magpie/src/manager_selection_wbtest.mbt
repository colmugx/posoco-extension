///|
/// manager_selection_wbtest.mbt — selection semantics through the
/// manager-neutral trait
/// (scenarios 9–10: provider/model and slash-less ids, 13–15: effort
/// selection, rejection, reset on switch; 20: snapshot isolation).

///|
/// A manager freshly connected over a catalog with the id shapes Magpie
/// actually serves: `provider/model`, `group/<id>` and a bare group name
/// with no slash at all, plus one model advertising efforts.
fn selection_manager() -> MagpieManager raise {
  let body = models_body(
    "\{model_entry(id="deepseek/deepseek-v4-pro")},\{model_entry(id="group/auto-gpt-6-luna", owned_by="codex")},\{model_entry(id="daily-coding", owned_by="group")},\{model_entry(id="muse/spark", name="Muse Spark", fields="\"reasoning\":true,\"supported_reasoning_levels\":[],\"context_window\":65536")},\{model_entry(id="zai/glm-5.3", owned_by="zai")}",
  )
  manager_with(transport=gateway(models=body), config=local_config())
}

///|
async test "selection keys are opaque: provider, group and slash-less ids" {
  let manager = selection_manager()
  let control = manager as &@modelmgmt.ModelManagerControl
  refresh_ok(manager)
  debug_inspect(
    ids(control.list_models()),
    content=(
      #|[
      #|  "deepseek/deepseek-v4-pro",
      #|  "group/auto-gpt-6-luna",
      #|  "daily-coding",
      #|  "muse/spark",
      #|  "zai/glm-5.3",
      #|]
    ),
  )
  control.select_model("deepseek/deepseek-v4-pro")
  inspect(control.active_selection().pending, content="false")
  control.select_model("group/auto-gpt-6-luna")
  inspect(
    selection_text(manager),
    content="group/auto-gpt-6-luna/-/pending=false",
  )
  control.select_model("daily-coding")
  inspect(selection_text(manager), content="daily-coding/-/pending=false")
}

///|
async test "supported effort applies; switching models resets it" {
  let manager = selection_manager()
  let control = manager as &@modelmgmt.ModelManagerControl
  refresh_ok(manager)
  control.select_model("deepseek/deepseek-v4-pro")
  control.select_effort("high")
  inspect(
    selection_text(manager),
    content="deepseek/deepseek-v4-pro/high/pending=false",
  )
  // Switching models resets the explicit effort.
  control.select_model("zai/glm-5.3")
  inspect(selection_text(manager), content="zai/glm-5.3/-/pending=false")
  // Re-selecting the same model resets as well.
  control.select_model("zai/glm-5.3")
  control.select_effort("low")
  control.select_model("zai/glm-5.3")
  inspect(selection_text(manager), content="zai/glm-5.3/-/pending=false")
}

///|
async test "unknown models and unadvertised efforts fail without mutating" {
  let manager = selection_manager()
  let control = manager as &@modelmgmt.ModelManagerControl
  refresh_ok(manager)
  control.select_model("deepseek/deepseek-v4-pro")
  control.select_effort("medium")
  let before = selection_text(manager)
  try control.select_model("nope/gone") catch {
    @modelmgmt.ModelManagerError::UnknownModel(_) => ()
    _ => fail("expected UnknownModel")
  } noraise {
    _ => fail("expected UnknownModel")
  }
  inspect(selection_text(manager), content=before)
  try control.select_effort("ultra") catch {
    @modelmgmt.ModelManagerError::UnsupportedEffort(detail) =>
      inspect(detail.contains("ultra"), content="true")
    _ => fail("expected UnsupportedEffort")
  } noraise {
    _ => fail("expected UnsupportedEffort")
  }
  inspect(selection_text(manager), content=before)
}

///|
async test "a model without advertised levels rejects every effort" {
  let manager = selection_manager()
  let control = manager as &@modelmgmt.ModelManagerControl
  refresh_ok(manager)
  control.select_model("muse/spark")
  try control.select_effort("high") catch {
    @modelmgmt.ModelManagerError::UnsupportedEffort(_) => ()
    _ => fail("expected UnsupportedEffort")
  } noraise {
    _ => fail("expected UnsupportedEffort")
  }
  inspect(selection_text(manager), content="muse/spark/-/pending=false")
}

///|
async test "effort without any selection is UnknownModel" {
  let manager = selection_manager()
  let control = manager as &@modelmgmt.ModelManagerControl
  refresh_ok(manager)
  try control.select_effort("high") catch {
    @modelmgmt.ModelManagerError::UnknownModel(_) => ()
    _ => fail("expected UnknownModel")
  } noraise {
    _ => fail("expected UnknownModel")
  }
}

///|
async test "catalog snapshots are isolated from the manager and each other" {
  let transport = FakeTransport([
    Respond(code=200, body=hello_body()),
    Respond(
      code=200,
      body=models_body("\{model_entry(id="a/one")},\{model_entry(id="b/two")}"),
    ),
    Respond(code=200, body=hello_body()),
    Respond(code=200, body=models_body(model_entry(id="fresh/one"))),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  // Mutating a snapshot changes nothing behind the trait.
  let first = manager.list_models()
  first[0].capabilities.push("hacked")
  first[0].efforts.push("hacked")
  let live = manager.list_models()
  debug_inspect(live[0].capabilities, content="[\"image\"]")
  debug_inspect(live[0].efforts, content="[\"low\", \"medium\", \"high\"]")
  inspect(live[0].label, content="Model")
  // Earlier snapshots keep whatever mutations were made to them, while a
  // second snapshot taken before those mutations is unaffected.
  let second = manager.list_models()
  debug_inspect(second[0].capabilities, content="[\"image\"]")
  // A later refresh that swaps the catalog never rewrites earlier snapshots.
  let before_refresh = manager.list_models()
  refresh_ok(manager)
  debug_inspect(ids(before_refresh), content="[\"a/one\", \"b/two\"]")
  debug_inspect(ids(manager.list_models()), content="[\"fresh/one\"]")
}

///|
async test "manager_id is the stable magpie identity" {
  let manager = selection_manager()
  let control = manager as &@modelmgmt.ModelManagerControl
  inspect(control.manager_id(), content="magpie")
}
