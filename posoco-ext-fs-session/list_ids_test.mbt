///|
/// list_ids_test.mbt — native tests for JsonlSessionStore::list_ids.

///|
/// Seed one persisted session by saving an empty session under `id`.
async fn seed_listed_session(store : JsonlSessionStore, id : String) -> Unit {
  store.save(id, @posoco.Session::{
    messages: [],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("seed save failed for \{id}: \{e}")
  }
}

///|
async test "io[native]: list_ids returns sorted stems of jsonl files only" {
  let root = fresh_root("list-mixed")
  let store = JsonlSessionStore::JsonlSessionStore(root)
  seed_listed_session(store, "cetas-100")
  seed_listed_session(store, "cetas-300")
  seed_listed_session(store, "cetas-20")
  // A sibling file that is not a session journal must not surface as an id.
  @xfs.write_string_to_file(root + "/notes.txt", "not a session") catch {
    _ => fail("seed sibling file failed")
  }
  let ids = store.list_ids() catch { e => fail("list_ids failed: \{e}") }
  // Lexicographic order — clock-minted ids therefore sort chronologically.
  assert_eq(ids, ["cetas-100", "cetas-20", "cetas-300"])
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: list_ids on an empty root is empty" {
  let root = fresh_root("list-empty")
  let store = JsonlSessionStore::JsonlSessionStore(root)
  let ids = store.list_ids() catch {
    e => fail("list_ids on empty root failed: \{e}")
  }
  assert_eq(ids, [])
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: list_ids on a missing root is empty" {
  let root = fresh_root("list-missing")
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
  let store = JsonlSessionStore::JsonlSessionStore(root)
  let ids = store.list_ids() catch {
    e => fail("list_ids on missing root failed: \{e}")
  }
  assert_eq(ids, [])
}
