///|
/// Read-only recovery evidence, not lock acquisition or execution authority.
pub async fn FileBoardExecutionStore::inspect(
  directory~ : String,
) -> Result[
  Array[@execution.BoardExecutionBinding],
  @execution.BoardExecutionError,
] {
  try {
    let path = directory + "/" + @node_fs.execution_journal_name
    if !@fs.exists(path) {
      return Ok([])
    }
    if @fs.kind(path, follow_symlink=false) != Regular {
      return Err(@execution.StoreUnavailable)
    }
    @execution.decode_execution_journal(@fs.read_file(path).text())
  } catch {
    _ => Err(@execution.StoreUnavailable)
  }
}
