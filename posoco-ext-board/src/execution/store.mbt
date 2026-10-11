///|
/// Ephemeral journal for tests and explicitly ephemeral hosts, not crash-safe.
pub struct MemoryBoardExecutionStore {
  priv mut records : Array[BoardExecutionBinding]
}

///|
/// ```mbt check
/// async test {
///   let store = @execution.MemoryBoardExecutionStore()
///   assert_eq(store.load(), Ok([]))
/// }
/// ```
pub fn MemoryBoardExecutionStore::MemoryBoardExecutionStore() -> MemoryBoardExecutionStore {
  { records: [], }
}

///|
pub extend MemoryBoardExecutionStore with BoardExecutionStore::{load, persist}

///|
pub impl BoardExecutionStore for MemoryBoardExecutionStore with fn load(self) {
  Ok(self.records.copy())
}

///|
pub impl BoardExecutionStore for MemoryBoardExecutionStore with fn persist(
  self,
  records,
) {
  match encode_execution_journal(records) {
    Ok(_) => {
      self.records = records.copy()
      Ok(())
    }
    Err(error) => Err(error)
  }
}
