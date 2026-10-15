///|
/// model_selection_test.mbt — native tests for the session model-selection
/// record: bus observation, save decoration, append fast-path line rewrite,
/// and the summary projection.

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
