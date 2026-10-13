///|
/// Contract tests driven exclusively through `&ModelManagerControl` trait
/// references against a deterministic in-memory manager — no router, no
/// ModelPort, no I/O.

///|
/// Minimal deterministic manager: catalog is fixed at construction, and
/// selection mutates only through the control methods.
struct FakeManager {
  id : String
  catalog : Array[ManagerModelInfo]
  mut selected : String
  mut effort : String?
}

///|
fn FakeManager::FakeManager(
  id~ : String,
  catalog~ : Array[ManagerModelInfo],
  selected~ : String,
) -> FakeManager {
  { id, catalog, selected, effort: None, }
}

///|
fn fake_model(id~ : String, efforts~ : Array[String]) -> ManagerModelInfo {
  {
    model_id: id,
    label: id,
    provider_id: "fake-provider",
    context_window: None,
    capabilities: ["chat"],
    efforts,
    default_effort: None,
    display_group: None,
  }
}

///|
fn FakeManager::fake_catalog_model(
  self : FakeManager,
  model_id : String,
) -> ManagerModelInfo? {
  let mut found : ManagerModelInfo? = None
  for m in self.catalog {
    if m.model_id == model_id {
      found = Some(m)
      break
    }
  }
  found
}

///|
fn FakeManager::fake_catalog_has(self : FakeManager, model_id : String) -> Bool {
  self.catalog.any(m => m.model_id == model_id)
}

///|
impl ModelManagerControl for FakeManager with fn manager_id(self : FakeManager) -> String {
  self.id
}

///|
impl ModelManagerControl for FakeManager with fn list_models(self : FakeManager) -> Array[
  ManagerModelInfo,
] {
  self.catalog.map(m => {
    ..m,
    capabilities: m.capabilities.copy(),
    efforts: m.efforts.copy(),
  })
}

///|
impl ModelManagerControl for FakeManager with fn active_selection(
  self : FakeManager,
) -> ManagerSelection {
  {
    model_id: self.selected,
    effort: self.effort,
    pending: !self.fake_catalog_has(self.selected),
  }
}

///|
impl ModelManagerControl for FakeManager with fn select_model(
  self : FakeManager,
  model_id : String,
) -> Unit raise ModelManagerError {
  if !self.fake_catalog_has(model_id) {
    raise ModelManagerError::UnknownModel("unknown model: " + model_id)
  }
  self.selected = model_id
  self.effort = None
}

///|
impl ModelManagerControl for FakeManager with fn select_effort(
  self : FakeManager,
  effort : String,
) -> Unit raise ModelManagerError {
  let model = match self.fake_catalog_model(self.selected) {
    Some(model) => model
    None =>
      raise ModelManagerError::UnknownModel(
        "active selection is pending: " + self.selected,
      )
  }
  if !model.efforts.contains(effort) {
    raise ModelManagerError::UnsupportedEffort(
      "unsupported effort '\{effort}' for model " + model.model_id,
    )
  }
  self.effort = Some(effort)
}

///|
fn fake_manager() -> &ModelManagerControl {
  FakeManager::FakeManager(
    id="fake",
    catalog=[
      fake_model(id="plain", efforts=[]),
      fake_model(id="deep", efforts=["low", "high"]),
    ],
    selected="plain",
  )
  as &ModelManagerControl
}

///|
test "the contract is drivable through a trait reference alone" {
  let manager = fake_manager()
  assert_eq(manager.manager_id(), "fake")
  assert_eq(manager.list_models().map(m => m.model_id), ["plain", "deep"])
  assert_eq(manager.active_selection().model_id, "plain")
  assert_false(manager.active_selection().pending)
  manager.select_model("deep")
  assert_eq(manager.active_selection().model_id, "deep")
  assert_eq(manager.active_selection().effort, None)
}

///|
test "catalog snapshots are isolated from later mutations" {
  let manager = fake_manager()
  let snapshot = manager.list_models()
  snapshot[0].capabilities.push("sneaky")
  snapshot[0].efforts.push("sneaky")
  assert_eq(manager.list_models()[0].capabilities, ["chat"])
  assert_eq(manager.list_models()[0].efforts, [])
}

///|
test "select_model rejects unknown ids without mutating state" {
  let manager = fake_manager()
  let result = Ok(manager.select_model("ghost")) catch { error => Err(error) }
  match result {
    Err(ModelManagerError::UnknownModel(detail)) =>
      assert_true(detail.contains("ghost"))
    _ => fail("expected UnknownModel")
  }
  assert_eq(manager.active_selection().model_id, "plain")
  assert_eq(manager.list_models().length(), 2)
}

///|
test "select_effort validates against the active model's advertised efforts" {
  let manager = fake_manager()
  let result = Ok(manager.select_effort("x")) catch { error => Err(error) }
  match result {
    Err(ModelManagerError::UnsupportedEffort(_)) => ()
    _ => fail("expected UnsupportedEffort for a model without efforts")
  }
}

///|
test "effort selection sticks until the model switches" {
  let manager = fake_manager()
  manager.select_model("deep")
  manager.select_effort("high")
  assert_eq(manager.active_selection().effort, Some("high"))
  manager.select_model("plain")
  assert_eq(manager.active_selection().effort, None)
  let result = Ok(manager.select_effort("high")) catch { error => Err(error) }
  match result {
    Err(ModelManagerError::UnsupportedEffort(_)) => ()
    _ => fail("expected UnsupportedEffort for a model without efforts")
  }
}

///|
test "a pending selection is reported, not rewritten" {
  let manager : &ModelManagerControl = FakeManager::FakeManager(
      id="fake",
      catalog=[fake_model(id="plain", efforts=[])],
      selected="ghost",
    )
    as &ModelManagerControl
  let selection = manager.active_selection()
  assert_eq(selection.model_id, "ghost")
  assert_true(selection.pending)
  let result = Ok(manager.select_effort("low")) catch { error => Err(error) }
  match result {
    Err(ModelManagerError::UnknownModel(_)) => ()
    _ => fail("expected UnknownModel for an effort on a pending selection")
  }
  assert_eq(manager.active_selection().model_id, "ghost")
  manager.select_model("plain")
  assert_false(manager.active_selection().pending)
}
