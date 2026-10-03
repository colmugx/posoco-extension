///|
async fn openai_version_read_file(path : String) -> String {
  @fs.read_file(path).text()
}

///|
async fn openai_version_write_atomic(
  directory : String,
  target : String,
  nonce : String,
  payload : String,
) -> Unit {
  @fs.mkdir(directory, recursive=true, allow_exist=true)
  let temporary = target + "." + nonce + ".tmp"
  @fs.write_file(
    temporary,
    payload,
    create_mode=@fs.CreateNew,
    permission=0o600,
  )
  // Registered only once this call owns the temporary: a failed CreateNew
  // must leave a colliding foreign file untouched, like the js guard.
  errdefer (@fs.remove(temporary) catch { _ => () })
  @fs.rename(temporary, target, replace=true)
}
