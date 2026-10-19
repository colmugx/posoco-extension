///|
/// Read-only recovery evidence; never acquires or removes an execution lock.
pub fn FileBoardExecutionStore::inspect(
  directory~ : String,
) -> Result[
  Array[@execution.BoardExecutionBinding],
  @execution.BoardExecutionError,
] {
  match @node_fs.read(directory + "/executions.json") {
    Ok(None) => Ok([])
    Ok(Some(text)) => @execution.decode_execution_journal(text)
    Err(_) => Err(@execution.StoreUnavailable)
  }
}
