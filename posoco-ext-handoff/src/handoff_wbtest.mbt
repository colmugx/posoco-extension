///|
priv struct FakeHandoffStore {
  mut dir : String
  mut path : String
  mut content : String
}

///|
fn FakeHandoffStore::new() -> FakeHandoffStore {
  { dir: "", path: "", content: "" }
}

///|
priv impl HandoffStore for FakeHandoffStore with fn exists(self, path) {
  Ok(self.path == path && self.content.length() > 0)
}

///|
priv impl HandoffStore for FakeHandoffStore with fn read(self, path) {
  if self.path == path && self.content.length() > 0 {
    Ok(self.content)
  } else {
    Err("missing: " + path)
  }
}

///|
priv impl HandoffStore for FakeHandoffStore with fn ensure_dir(self, path) {
  self.dir = path
  Ok(())
}

///|
priv impl HandoffStore for FakeHandoffStore with fn write_atomic(
  self,
  path,
  content,
) {
  self.path = path
  self.content = content
  Ok(())
}

///|
priv struct FixedHandoffProbe {
  workspace : WorkspaceSnapshot
}

///|
priv impl HandoffWorkspaceProbe for FixedHandoffProbe with fn snapshot(
  self,
  _cwd,
) {
  Ok({ ..self.workspace, changes: self.workspace.changes.copy() })
}

///|
priv struct FixedHandoffWork {
  work : WorkSnapshot
}

///|
priv impl HandoffWorkSource for FixedHandoffWork with fn handoff_work(self) {
  self.work
}

///|
async test "handoff/create writes project-root document" {
  let store = FakeHandoffStore::new()
  let probe = FixedHandoffProbe::{
    workspace: {
      root: "/repo",
      branch: Some("feat/handoff"),
      head: Some("abc123"),
      changes: [{ path: "src/a.mbt", status: "modified" }],
    },
  }
  let source = FixedHandoffWork::{
    work: {
      ..WorkSnapshot::empty(),
      objective: Some("Finish handoff"),
      current_work: Some("Test command flow"),
      next_action: Some("Run moon test"),
    },
  }
  let handoff = Handoff::new(
    cwd="/repo/src/nested",
    store=store,
    probe=probe,
    work_sources=[source],
  )
  let outcome = handoff.invoke("handoff", Json::string("create"))
  assert_true(outcome is @posoco.CommandOutcome::Success(..))
  assert_eq(store.dir, "/repo/.handoff")
  assert_eq(store.path, "/repo/.handoff/HANDOFF.md")
  assert_true(store.content.contains("## Objective"))
  assert_true(store.content.contains("Finish handoff"))
  assert_true(store.content.contains("Test command flow"))
}

///|
async test "handoff/inspect reads the same project-root document" {
  let store = FakeHandoffStore::new()
  store.dir = "/repo/.handoff"
  store.path = "/repo/.handoff/HANDOFF.md"
  store.content = "# Handoff\n\nexisting\n"
  let probe = FixedHandoffProbe::{
    workspace: {
      root: "/repo",
      branch: None,
      head: None,
      changes: [],
    },
  }
  let handoff = Handoff::new(
    cwd="/repo/src",
    store=store,
    probe=probe,
    work_sources=[],
  )
  let outcome = handoff.invoke("handoff", Json::string("inspect"))
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ui_hint~) => {
      ignore(structured)
      ignore(ui_hint)
      assert_eq(feedback, "# Handoff\n\nexisting\n")
    }
    _ => fail("inspect should return the stored HANDOFF.md")
  }
}

///|
async test "handoff/create refuses incomplete continuation state" {
  let store = FakeHandoffStore::new()
  let probe = FixedHandoffProbe::{
    workspace: { root: "/repo", branch: None, head: None, changes: [] },
  }
  let handoff = Handoff::new(
    cwd="/repo",
    store=store,
    probe=probe,
    work_sources=[],
  )
  let outcome = handoff.invoke("handoff", Json::string("create"))
  match outcome {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("objective"))
    _ => fail("incomplete handoff must fail")
  }
  assert_eq(store.path, "")
}
