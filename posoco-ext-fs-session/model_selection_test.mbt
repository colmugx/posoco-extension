///|
/// model_selection_test.mbt — native tests for the session model-selection
/// record: bus observation, save decoration, append fast-path line rewrite,
/// and the summary projection.

///|
test "v2 selection preserves ownership and fails closed on mismatches" {
  let selection : @posoco-ext-fs-session.SessionSelectionV2 = {
    owner: "manager-a",
    model_id: "same/model",
    effort: Some("high"),
    pending: false,
    revision: 9L,
  }
  let metadata = @posoco-ext-fs-session.metadata_with_selection_v2(
    Map::from_array([]),
    selection,
  )
  assert_true(@posoco-ext-fs-session.session_selection_v2_for_owner(
    metadata, "manager-b",
  ) is None)
  match @posoco-ext-fs-session.session_selection_v2_for_owner(
    metadata, "manager-a",
  ) {
    Some(found) => assert_eq(found, selection)
    None => fail("owner-qualified v2 selection was lost")
  }
  let malformed = metadata.copy()
  malformed[@posoco-ext-fs-session.MODEL_SELECTION_V2_METADATA_KEY] =
    Json::object(Map::from_array([
      ("version", Json::number(2)),
      ("owner", Json::string("")),
      ("model_id", Json::string("same/model")),
    ]))
  assert_true(@posoco-ext-fs-session.session_selection_v2_from_metadata(
    malformed,
  ) is None)
}

///|
/// Publish one `model_selection` bus event the way ext-llm's router does.
fn publish_selection(
  bus : @devkit.EventBus,
  source~ : String = "posoco_ext_llm",
  topic~ : String = "model_selection",
  slot~ : String,
  effort~ : String? = None,
) -> Unit {
  bus.publish({
    source,
    topic,
    data: Json::object(
      Map::from_array([
        ("slot_id", Json::string(slot)),
        (
          "effort",
          match effort {
            Some(value) => Json::string(value)
            None => Json::null()
          },
        ),
      ]),
    ),
  })
}

///|
fn selection_test_message(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
/// First physical line of a stored journal, for byte-level line-1 checks.
fn stored_metadata_line(root : String, id : String) -> String raise {
  let path = @posoco-ext-fs-session.jsonl_session_path(root, id)
  let content = @xfs.read_file_to_string(path) catch {
    _ => fail("read failed")
  }
  match content.split("\n").next() {
    Some(line) => line.to_owned()
    None => fail("empty journal")
  }
}

///|
/// Pure codec: the metadata round-trip parses back to the same selection.
test "model selection metadata round-trips" {
  let metadata : Map[String, Json] = Map::from_array([])
  assert_true(
    @posoco-ext-fs-session.model_selection_from_metadata(metadata) is None,
  )
  metadata[@posoco-ext-fs-session.MODEL_SELECTION_METADATA_KEY] = Json::object(
    Map::from_array([
      ("slot_id", Json::string("qwen/glm-4.6")),
      ("effort", Json::string("high")),
    ]),
  )
  match @posoco-ext-fs-session.model_selection_from_metadata(metadata) {
    Some((slot, effort)) => {
      assert_eq(slot, "qwen/glm-4.6")
      assert_eq(effort, Some("high"))
    }
    None => fail("expected slot+effort")
  }
  metadata[@posoco-ext-fs-session.MODEL_SELECTION_METADATA_KEY] = Json::object(
    Map::from_array([("slot_id", Json::string("qwen/glm-4.6"))]),
  )
  match @posoco-ext-fs-session.model_selection_from_metadata(metadata) {
    Some((slot, effort)) => {
      assert_eq(slot, "qwen/glm-4.6")
      assert_eq(effort, None)
    }
    None => fail("expected slot without effort")
  }
  // Malformed payloads never surface as a selection.
  metadata[@posoco-ext-fs-session.MODEL_SELECTION_METADATA_KEY] = Json::string(
    "nope",
  )
  assert_true(
    @posoco-ext-fs-session.model_selection_from_metadata(metadata) is None,
  )
  metadata[@posoco-ext-fs-session.MODEL_SELECTION_METADATA_KEY] = Json::object(
    Map::from_array([("slot_id", Json::string(""))]),
  )
  assert_true(
    @posoco-ext-fs-session.model_selection_from_metadata(metadata) is None,
  )
}

///|
test "metadata line rewrite touches line 1 only and keeps torn tails" {
  let content = "{\"a\":1}\n{\"role\":\"user\"}\n{\"rol"
  match
    @posoco-ext-fs-session.rewrite_metadata_line(
      content,
      Some(("p/m", Some("low"))),
    ) {
    Some(updated) => {
      let parts : Array[String] = []
      for part in updated.split("\n") {
        parts.push(part.to_owned())
      }
      assert_eq(parts.length(), 3)
      assert_true(parts[0].contains("\"slot_id\":\"p/m\""))
      assert_eq(parts[1], "{\"role\":\"user\"}")
      assert_eq(parts[2], "{\"rol")
    }
    None => fail("expected a rewrite")
  }
  // No line break, non-object line, or absent selection → no rewrite.
  assert_true(
    @posoco-ext-fs-session.rewrite_metadata_line("{}", Some(("p/m", None)))
    is None,
  )
  assert_true(
    @posoco-ext-fs-session.rewrite_metadata_line("null\nx", Some(("p/m", None)))
    is None,
  )
  assert_true(
    @posoco-ext-fs-session.rewrite_metadata_line("{\"a\":1}\n", None) is None,
  )
}

///|
async test "io[native]: observed selection decorates the next save" {
  let root = fresh_root("selection-save")
  let bus = @devkit.EventBus()
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(
    root,
    bus=Some(bus),
  )
  publish_selection(bus, slot="qwen/glm-4.6", effort=Some("high"))
  store.save("sess_sel", {
    messages: [selection_test_message("hi")],
    metadata: Map::from_array([("name", Json::string("keep"))]),
  }) catch {
    e => fail("save failed: \{e}")
  }
  let s = store.summary("sess_sel") catch { e => fail("summary failed: \{e}") }
  assert_eq(s.model, Some("qwen/glm-4.6"))
  assert_eq(s.effort, Some("high"))
  // Pre-existing metadata keys survive the decoration.
  assert_eq(s.name, Some("keep"))
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: no observation leaves metadata untouched" {
  let root = fresh_root("selection-legacy")
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(root)
  store.save("sess_plain", {
    messages: [selection_test_message("hi")],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("save failed: \{e}")
  }
  let s = store.summary("sess_plain") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(s.model, None)
  assert_eq(s.effort, None)
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: foreign bus traffic is ignored" {
  let root = fresh_root("selection-foreign")
  let bus = @devkit.EventBus()
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(
    root,
    bus=Some(bus),
  )
  publish_selection(bus, source="other_ext", slot="a/b")
  publish_selection(bus, topic="model", slot="a/b")
  store.save("sess_foreign", { messages: [], metadata: Map::from_array([]), }) catch {
    e => fail("save failed: \{e}")
  }
  let s = store.summary("sess_foreign") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(s.model, None)
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: first append creates a decorated journal" {
  let root = fresh_root("selection-first-append")
  let bus = @devkit.EventBus()
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(
    root,
    bus=Some(bus),
  )
  publish_selection(bus, slot="z/d")
  let messages = [selection_test_message("first")]
  store.append_messages("sess_fresh", 0, messages[:]) catch {
    e => fail("append failed: \{e}")
  }
  let s = store.summary("sess_fresh") catch {
    e => fail("summary failed: \{e}")
  }
  assert_eq(s.model, Some("z/d"))
  assert_eq(s.effort, None)
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: append rewrites line 1 after a selection change" {
  let root = fresh_root("selection-append")
  let bus = @devkit.EventBus()
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(
    root,
    bus=Some(bus),
  )
  store.save("sess_app", {
    messages: [selection_test_message("one")],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("save failed: \{e}")
  }
  let before = stored_metadata_line(root, "sess_app")
  assert_true(!before.contains("slot_id"))
  publish_selection(bus, slot="qwen/glm-4.6", effort=Some("high"))
  store.append_messages("sess_app", 1, [selection_test_message("two")][:]) catch {
    e => fail("append failed: \{e}")
  }
  let s = store.summary("sess_app") catch { e => fail("summary failed: \{e}") }
  assert_eq(s.model, Some("qwen/glm-4.6"))
  assert_eq(s.effort, Some("high"))
  assert_eq(s.title, Some("one"))
  // Both messages survived the line-1 rewrite.
  let reloaded = store.load("sess_app") catch {
    e => fail("reload failed: \{e}")
  }
  assert_eq(reloaded.messages.length(), 2)
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: append without a change keeps the metadata line" {
  let root = fresh_root("selection-fastpath")
  let bus = @devkit.EventBus()
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(
    root,
    bus=Some(bus),
  )
  publish_selection(bus, slot="a/b")
  store.save("sess_fast", {
    messages: [selection_test_message("one")],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("save failed: \{e}")
  }
  let before = stored_metadata_line(root, "sess_fast")
  store.append_messages("sess_fast", 1, [selection_test_message("two")][:]) catch {
    e => fail("append failed: \{e}")
  }
  // The already-recorded selection is left verbatim.
  assert_eq(stored_metadata_line(root, "sess_fast"), before)
  let reloaded = store.load("sess_fast") catch {
    e => fail("reload failed: \{e}")
  }
  assert_eq(reloaded.messages.length(), 2)
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: corrupt metadata line is skipped, not crashed on" {
  let root = fresh_root("selection-corrupt")
  let bus = @devkit.EventBus()
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(
    root,
    bus=Some(bus),
  )
  store.save("sess_bad", {
    messages: [selection_test_message("one")],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("save failed: \{e}")
  }
  // Simulate a corrupt metadata line directly on disk.
  let path = @posoco-ext-fs-session.jsonl_session_path(root, "sess_bad")
  @xfs.write_string_to_file(path, "not-json\n{corrupt") catch {
    _ => fail("seed corrupt failed")
  }
  publish_selection(bus, slot="a/b")
  store.append_messages("sess_bad", 1, [selection_test_message("two")][:]) catch {
    e => fail("append should not raise on corrupt line 1: \{e}")
  }
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: checkpoint with metadata keeps the selection record" {
  let root = fresh_root("selection-checkpoint")
  let bus = @devkit.EventBus()
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(
    root,
    bus=Some(bus),
  )
  publish_selection(bus, slot="a/b", effort=Some("low"))
  store.save("sess_ckpt", {
    messages: [selection_test_message("one")],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("save failed: \{e}")
  }
  store.checkpoint("sess_ckpt", {
    from_index: 1,
    messages: [selection_test_message("two")],
    metadata: Some(Map::from_array([("posoco.title", Json::string("auto"))])),
  }) catch {
    e => fail("checkpoint failed: \{e}")
  }
  let s = store.summary("sess_ckpt") catch { e => fail("summary failed: \{e}") }
  assert_eq(s.model, Some("a/b"))
  assert_eq(s.effort, Some("low"))
  assert_eq(s.title, Some("auto"))
  let reloaded = store.load("sess_ckpt") catch {
    e => fail("reload failed: \{e}")
  }
  assert_eq(reloaded.messages.length(), 2)
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: v2 injection persists on save and append" {
  let root = fresh_root("selection-v2")
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(root)
  let first : @posoco-ext-fs-session.SessionSelectionV2 = {
    owner: "owned-manager",
    model_id: "opaque-one",
    effort: Some("high"),
    pending: false,
    revision: 1L,
  }
  store.observe_selection_v2(first)
  store.save("sess_v2", {
    messages: [selection_test_message("first")],
    metadata: Map::from_array([]),
  }) catch { e => fail("v2 save failed: \{e}") }
  let saved = store.load("sess_v2") catch {
    e => fail("v2 load failed: \{e}")
  }
  assert_eq(
    @posoco-ext-fs-session.session_selection_v2_from_metadata(saved.metadata),
    Some(first),
  )
  let second = { ..first, model_id: "opaque-two", revision: 2L, }
  store.observe_selection_v2(second)
  store.append_messages("sess_v2", 1, [selection_test_message("next")][:]) catch {
    e => fail("v2 append failed: \{e}")
  }
  let reread = store.load("sess_v2") catch {
    e => fail("v2 reread failed: \{e}")
  }
  assert_eq(reread.messages.length(), 2)
  assert_eq(
    @posoco-ext-fs-session.session_selection_v2_for_owner(
      reread.metadata, "owned-manager",
    ),
    Some(second),
  )
  assert_true(
    @posoco-ext-fs-session.session_selection_v2_for_owner(
      reread.metadata, "other-manager",
    ) is None,
  )
  @fs.rmdir(root, recursive=true) catch { _ => () }
}

 
///|
async test "io[native]: lookup projects an owner-scoped neutral selection ref" {
  let root = fresh_root("selection-owner-lookup")
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(root)
  let value : @posoco-ext-fs-session.SessionSelectionV2 = {
    owner: "bound-manager",
    model_id: "opaque-model",
    effort: Some("high"),
    pending: false,
    revision: 8L,
  }
  store.observe_selection_v2(value)
  store.save("sess_owner", {
    messages: [selection_test_message("work")],
    metadata: Map::from_array([]),
  }) catch { e => fail("save failed: \{e}") }
  let owned = store.selection_for_owner("sess_owner", "bound-manager") catch {
    e => fail("lookup failed: \{e}")
  }
  match owned {
    Some(value) => {
      assert_eq(value.owner, "bound-manager")
      assert_eq(value.model_id, "opaque-model")
      assert_eq(value.revision, 8L)
    }
    None => fail("missing owned selection")
  }
  let foreign = store.selection_for_owner("sess_owner", "different") catch {
    e => fail("lookup failed: \{e}")
  }
  assert_true(foreign is None)
  @fs.rmdir(root, recursive=true) catch { _ => () }
}

///|
async test "io[native]: control snapshot follows committed selection across journals" {
  let root = fresh_root("selection-control")
  let control = TestSelectionControl::{
    current: "first",
    owner: "neutral-manager",
  }
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(
    root,
    selection_control=Some(control as &@modelmgmt.ModelManagerControl),
  )
  store.save("sess_alpha", {
    messages: [selection_test_message("a")],
    metadata: Map::from_array([]),
  }) catch { e => fail("save alpha: \{e}") }
  control.current = "second"
  store.save("sess_beta", {
    messages: [selection_test_message("b")],
    metadata: Map::from_array([]),
  }) catch { e => fail("save beta: \{e}") }
  store.append_messages("sess_alpha", 1, [selection_test_message("c")][:]) catch {
    e => fail("append alpha: \{e}")
  }
  let persisted = store.selection_for_owner("sess_alpha", "neutral-manager") catch {
    e => fail("read alpha: \{e}")
  }
  match persisted {
    Some(selection) => assert_eq(selection.model_id, "second")
    None => fail("missing selection snapshot")
  }
  @fs.rmdir(root, recursive=true) catch { _ => () }
}

///|
struct TestSelectionControl {
  mut current : String
  owner : String
}

///|
pub impl @modelmgmt.ModelManagerControl for TestSelectionControl with fn manager_id(
  self : TestSelectionControl,
) -> String { self.owner }

///|
pub impl @modelmgmt.ModelManagerControl for TestSelectionControl with fn list_models(
  _self : TestSelectionControl,
) -> Array[@modelmgmt.ManagerModelInfo] { [] }

///|
pub impl @modelmgmt.ModelManagerControl for TestSelectionControl with fn active_selection(
  self : TestSelectionControl,
) -> @modelmgmt.ManagerSelection {
  { model_id: self.current, effort: None, pending: false }
}

///|
pub impl @modelmgmt.ModelManagerControl for TestSelectionControl with fn select_model(
  self : TestSelectionControl,
  model_id : String,
) -> Unit raise @modelmgmt.ModelManagerError {
  self.current = model_id
}

///|
pub impl @modelmgmt.ModelManagerControl for TestSelectionControl with fn select_effort(
  _self : TestSelectionControl,
  _effort : String,
) -> Unit raise @modelmgmt.ModelManagerError { () }
