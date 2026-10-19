///|
/// Compatibility surface for existing Native hosts; persistence is implemented
/// once in execution/file, which also provides the Node-compatible adapter.
pub struct FileBoardExecutionStore {
  priv inner : @file.FileBoardExecutionStore
}

///|
pub(all) enum JournalFailure {
  BeforeRename
  AfterRename
} derive(Eq)

///|
pub extend JournalFailure with Eq::{equal, not_equal}

///|
pub fn FileBoardExecutionStore::FileBoardExecutionStore(
  directory~ : String,
  fail_at? : JournalFailure,
) -> FileBoardExecutionStore {
  let fail_at = fail_at.map(stage => {
    match stage {
      BeforeRename => @file.JournalFailure::BeforeRename
      AfterRename => @file.JournalFailure::AfterRename
    }
  })
  { inner: @file.FileBoardExecutionStore(directory~, fail_at?), }
}

///|
pub impl @execution.BoardExecutionStore for FileBoardExecutionStore with fn load(
  self,
) {
  self.inner.load()
}

///|
pub impl @execution.BoardExecutionStore for FileBoardExecutionStore with fn persist(
  self,
  records,
) {
  self.inner.persist(records)
}

///|
pub extend FileBoardExecutionStore with @execution.BoardExecutionStore::{
  load,
  persist,
}

///|
pub async fn FileBoardExecutionStore::close(
  self : FileBoardExecutionStore,
) -> Unit {
  self.inner.close()
}
