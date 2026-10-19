///|
/// Node-compatible durable identity journal; the extension owns lock lifetime.
/// Ambiguous writes poison this instance. Nothing automatically replays them.
pub struct FileBoardExecutionStore {
  priv directory : String
  priv fail_at : JournalFailure?
  priv mut token : String?
  priv mut failed : Bool
}

///|
pub fn FileBoardExecutionStore::FileBoardExecutionStore(
  directory~ : String,
  fail_at? : JournalFailure,
) -> FileBoardExecutionStore {
  { directory, fail_at, token: None, failed: false, }
}

///|
pub extend FileBoardExecutionStore with @execution.BoardExecutionStore::{
  load,
  persist,
}

///|
pub impl @execution.BoardExecutionStore for FileBoardExecutionStore with fn load(
  self,
) {
  if self.failed {
    return Err(@execution.StoreUnavailable)
  }
  if self.token is None {
    match @node_fs.acquire(self.directory) {
      Ok(token) => self.token = Some(token)
      Err(_) => {
        self.failed = true
        return Err(@execution.StoreUnavailable)
      }
    }
  }
  match @node_fs.read(self.directory + "/executions.json") {
    Ok(None) => Ok([])
    Ok(Some(text)) => {
      let result = @execution.decode_execution_journal(text)
      if result is Err(_) {
        self.failed = true
      }
      result
    }
    Err(_) => {
      self.failed = true
      Err(@execution.StoreUnavailable)
    }
  }
}

///|
pub impl @execution.BoardExecutionStore for FileBoardExecutionStore with fn persist(
  self,
  records,
) {
  if self.failed || self.token is None {
    return Err(@execution.StoreUnavailable)
  }
  let text = match @execution.encode_execution_journal(records) {
    Ok(text) => text
    Err(error) => return Err(error)
  }
  let stage = match self.fail_at {
    Some(BeforeRename) => 5
    Some(AfterRename) => 6
    None => 0
  }
  if @node_fs.replace(self.directory, "executions.json", text, "", stage) == 0 {
    Ok(())
  } else {
    self.failed = true
    Err(@execution.StoreUnavailable)
  }
}

///|
/// Only after confirmed join. Wrong-token or filesystem failures are surfaced;
/// they never grant another owner permission to execute.
pub async fn FileBoardExecutionStore::close(
  self : FileBoardExecutionStore,
) -> Unit {
  @async.protect_from_cancel(() => {
    if self.token is Some(token) {
      if @node_fs.release(self.directory, token) is Err(_) {
        raise CloseFailed
      }
      self.token = None
    }
  })
}

///|
priv suberror JournalCloseError {
  CloseFailed
}
