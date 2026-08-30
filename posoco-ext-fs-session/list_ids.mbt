///|
/// list_ids.mbt — session id listing, shared by both targets. The pure
/// entry-filtering lives here; each backend supplies `raw_dir_entries`.

///|
/// List every persisted session id in this store's root: the file stems of
/// `<id>.jsonl` entries, re-checked by `validate_session_id`, deduplicated,
/// sorted lexicographically (clock-minted ids therefore sort
/// chronologically). A missing root is an empty list — the same
/// missing-means-empty rule `load` applies to a missing session file.
pub async fn JsonlSessionStore::list_ids(
  self : JsonlSessionStore,
) -> Array[String] raise @posoco.SessionError {
  session_ids_from_dir_entries(self.raw_dir_entries())
}

///|
/// Filter raw directory entries down to validated, deduplicated, sorted
/// `<id>.jsonl` stems. Non-`.jsonl` files and stems that fail validation
/// are ignored: only names this store could itself have written are
/// addressable sessions.
fn session_ids_from_dir_entries(entries : Array[String]) -> Array[String] {
  let ids : Array[String] = []
  for entry in entries {
    if entry.has_suffix(".jsonl") {
      let stem = entry.sub(start=0, end=entry.length() - 6).to_owned()
      if validate_session_id(stem) is Ok(_) && !ids.contains(stem) {
        ids.push(stem)
      }
    }
  }
  // Explicit char-lexicographic order (not MoonBit's length-first String
  // Ord): clock-minted `cetas-<ms>[-seq]` ids then sort chronologically.
  ids.sort_by(fn(a, b) {
    let shared = if a.length() < b.length() { a.length() } else { b.length() }
    for i = 0; i < shared; i = i + 1 {
      let ca = a[i]
      let cb = b[i]
      if ca != cb {
        if ca < cb {
          return -1
        }
        return 1
      }
    }
    if a.length() == b.length() {
      0
    } else if a.length() < b.length() {
      -1
    } else {
      1
    }
  })
  ids
}
