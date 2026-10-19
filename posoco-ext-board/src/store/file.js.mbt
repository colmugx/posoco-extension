///|
/// Node-compatible adapter. Schema and audit validation stay in shared MoonBit
/// codecs; only filesystem visibility/sync operations cross the JS boundary.
pub struct FileBoardStore {
  priv directory : String
  priv fail_at : StoreFailureStage?
}

///|
pub fn FileBoardStore::FileBoardStore(
  root~ : String = ".",
  fail_at~ : StoreFailureStage? = None,
) -> FileBoardStore {
  {
    directory: (if root.is_empty() { "." } else { root }) +
    "/.cetas/board/default",
    fail_at,
  }
}

///|
pub fn FileBoardStore::at_directory(
  directory~ : String,
  fail_at? : StoreFailureStage,
) -> FileBoardStore {
  { directory, fail_at, }
}

///|
pub extend FileBoardStore with BoardStore::{load, persist}

///|
fn FileBoardStore::read(
  self : FileBoardStore,
  name : String,
) -> Result[String?, BoardStoreError] {
  @node_fs.read(self.directory + "/" + name).map_err(_ => {
    Io("Board file read failed")
  })
}

///|
pub impl BoardStore for FileBoardStore with fn load(self) {
  let journal_text = match self.read("events.jsonl") {
    Ok(value) => value.unwrap_or("")
    Err(error) => return Err(error)
  }
  let journal = match scan_journal(journal_text) {
    Ok(scan) => scan.journal
    Err(error) => return Err(error)
  }
  let snapshot = match self.read("board.json") {
    Err(error) => return Err(error)
    Ok(None) => empty_snapshot()
    Ok(Some(text)) =>
      match decode_snapshot(text) {
        Ok(snapshot) => snapshot
        Err(error) => return Err(error)
      }
  }
  Ok({ snapshot, journal, })
}

///|
pub impl BoardStore for FileBoardStore with fn persist(self, snapshot, events) {
  let board = match encode_snapshot(copy_snapshot(snapshot)) {
    Ok(text) => text
    Err(error) => return Err(error)
  }
  let old = match self.read("events.jsonl") {
    Ok(text) => text.unwrap_or("")
    Err(error) => return Err(error)
  }
  let scan = match scan_journal(old) {
    Ok(scan) => scan
    Err(error) => return Err(error)
  }
  let lines : Array[String] = []
  if scan.add_newline {
    lines.push("\n")
  }
  for record in records(snapshot.revision, copy_events(events)) {
    match encode_journal_record(record) {
      Ok(line) => lines.push(line + "\n")
      Err(error) => return Err(error)
    }
  }
  let audit : Json = { "retained": scan.retained, "append": lines.join("") }
  let stage = match self.fail_at {
    None => 0
    Some(TempWrite) => 1
    Some(TempFsync) => 2
    Some(JournalAppend) => 3
    Some(JournalFsync) => 4
    Some(Rename) => 5
    Some(DirectoryFsync) => 6
  }
  match
    @node_fs.replace(
      self.directory,
      "board.json",
      board,
      audit.stringify(),
      stage,
    ) {
    0 => Ok(())
    3 => Err(DurabilityUncertain("Board snapshot visible; sync unconfirmed"))
    _ =>
      match self.fail_at {
        Some(stage) => Err(Injected(stage))
        None => Err(Io("Board persistence failed before visibility"))
      }
  }
}
