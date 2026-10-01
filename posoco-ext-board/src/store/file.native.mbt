///|
/// Native single-writer POSIX snapshot store. board.json is authoritative;
/// events.jsonl is audit only, including records ahead of a failed rename.
/// No cross-process locking, replay, or automatic temp-file promotion.
pub struct FileBoardStore {
  priv directory : String
  priv fail_at : StoreFailureStage?
}

///|
pub fn FileBoardStore::FileBoardStore(
  root? : String = ".",
  fail_at? : StoreFailureStage? = None,
) -> FileBoardStore {
  let root = if root.is_empty() { "." } else { root }
  { directory: root + "/.cetas/board/default", fail_at, }
}

///|
pub extend FileBoardStore with BoardStore::{load, persist}

///|
priv suberror FileStoreFailure {
  StoreFailure(BoardStoreError)
}

///|
fn FileBoardStore::stage(
  self : FileBoardStore,
  stage : StoreFailureStage,
) -> Unit raise FileStoreFailure {
  if self.fail_at == Some(stage) {
    raise StoreFailure(Injected(stage))
  }
}

///|
fn[T] checked(result : Result[T, BoardStoreError]) -> T raise FileStoreFailure {
  match result {
    Ok(value) => value
    Err(error) => raise StoreFailure(error)
  }
}

///|
fn parent_directory(path : String) -> String {
  let mut end = path.length()
  while end > 1 && path[end - 1] == '/' {
    end = end - 1
  }
  for i = end - 1; i >= 0; i = i - 1 {
    if path[i] == '/' {
      return if i == 0 { "/" } else { path[:i].to_owned() }
    }
  }
  "."
}

///|
extern "c" fn truncate_file(fd : Int, length : Int64) -> Int = "board_store_truncate"

///|
async fn FileBoardStore::journal(self : FileBoardStore) -> Bytes {
  let path = self.directory + "/events.jsonl"
  if @fs.exists(path) {
    @fs.read_file(path).binary()
  } else {
    b""
  }
}

///|
fn strict_utf8(bytes : BytesView) -> String raise FileStoreFailure {
  @utf8.decode(bytes, ignore_bom=false) catch {
    _ => raise StoreFailure(InvalidData("invalid UTF-8"))
  }
}

///|
fn scan_journal_bytes(bytes : Bytes) -> JournalScan raise FileStoreFailure {
  let mut end = 0
  for i = 0; i < bytes.length(); i = i + 1 {
    if bytes[i] == 10 {
      end = i + 1
    }
  }
  let prefix = strict_utf8(bytes[:end])
  // A torn UTF-8 sequence is permitted only in the unterminated tail.
  let tail = @utf8.decode(bytes[end:], ignore_bom=false) catch { _ => "" }
  checked(scan_journal(prefix + tail))
}

///|
pub impl BoardStore for FileBoardStore with fn load(self) {
  try {
    // Validate the audit but never use it to synthesize authoritative state.
    let scan = scan_journal_bytes(self.journal())
    let board = self.directory + "/board.json"
    let snapshot = if @fs.exists(board) {
      checked(decode_snapshot(strict_utf8(@fs.read_file(board).binary())))
    } else {
      empty_snapshot()
    }
    Ok({ snapshot, journal: scan.journal, })
  } catch {
    StoreFailure(error) => Err(error)
    error => Err(Io(error.to_string()))
  }
}

///|
pub impl BoardStore for FileBoardStore with fn persist(self, snapshot, events) {
  // Detach and encode before any asynchronous filesystem call.
  let snapshot = copy_snapshot(snapshot)
  let events = copy_events(events)
  let board = match encode_snapshot(snapshot) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let lines : Array[String] = []
  for record in records(snapshot.revision, events) {
    match encode_journal_record(record) {
      Ok(value) => lines.push(value + "\n")
      Err(error) => return Err(error)
    }
  }
  let temp_path = self.directory + "/board.json.tmp"
  let renamed = Ref(false)
  try {
    @async.protect_from_cancel(() => {
      @fs.mkdir(self.directory, recursive=true, allow_exist=true)
      let old_journal = self.journal()
      let scan = scan_journal_bytes(old_journal)
      // Fixed temp filename is intentional: serialized writers only. A stale
      // temp is truncated on write and is never read on load.
      self.stage(TempWrite)
      let temp = @fs.open(
        temp_path,
        mode=WriteOnly,
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
      defer temp.close()
      temp.write(board)
      self.stage(TempFsync)
      temp.sync()
      self.stage(JournalAppend)
      let journal = @fs.open(
        self.directory + "/events.jsonl",
        mode=WriteOnly,
        create_mode=OpenOrCreate,
        append=true,
        permission=0o600,
      )
      defer journal.close()
      let retained_length = @utf8.encode(scan.retained).length()
      if retained_length != old_journal.length() {
        let status = truncate_file(journal.fd(), retained_length.to_int64())
        if status != 0 {
          raise StoreFailure(Io("journal truncate errno \{status}"))
        }
      }
      if scan.add_newline {
        journal.write("\n")
      }
      for line in lines {
        journal.write(line)
      }
      self.stage(JournalFsync)
      journal.sync()
      self.stage(Rename)
      @fs.rename(temp_path, self.directory + "/board.json", replace=true)
      renamed.val = true
      self.stage(DirectoryFsync)
      // Sync ancestors too: a previous failed write may have created them
      // without syncing their directory entries before this retry.
      let mut path = self.directory
      while true {
        let directory = @fs.open(path, mode=ReadOnly)
        defer directory.close()
        directory.sync()
        let parent = parent_directory(path)
        if parent == path {
          break
        }
        path = parent
      }
    })
    Ok(())
  } catch {
    error => {
      // Cleanup must not mask the primary failure, even under cancellation.
      @async.protect_from_cancel(() => @fs.remove(temp_path) catch { _ => () })
      if renamed.val {
        Err(DurabilityUncertain(error.to_string()))
      } else {
        match error {
          StoreFailure(error) => Err(error)
          error => Err(Io(error.to_string()))
        }
      }
    }
  }
}
