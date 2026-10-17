///|
/// Cryptographic binding of exact normalized proposal (including revision).
/// JSON serialization is deterministic here: only typed arrays, no map order.
fn proposal_digest(draft : DraftExpansion) -> String {
  let tasks : Array[Json] = draft.tasks.map(task => {
    let deps : Array[Json] = task.depends_on.map(dep => {
      match dep {
        NewTask(key~) => ["local", key]
        ExistingTask(id~) => ["existing", id.value]
      }
    })
    let dod : Array[Json] = task.definition_of_done.map(s => Json::string(s))
    [
      task.key,
      task.title,
      task.description,
      task.priority.rank(),
      Json::array(dod),
      Json::array(deps),
    ]
  })
  let json : Json = [
    1,
    draft.proposal_id,
    draft.parent_task_id,
    draft.base_revision.to_string(),
    Json::array(tasks),
  ]
  sha256_text(json.stringify())
}

///|
fn sha256_text(text : String) -> String {
  let bytes = @crypto.sha256(@utf8.encode(text.view()))
  let buf = StringBuilder()
  buf.write_string("sha256:")
  let hex = "0123456789abcdef"
  for byte in bytes {
    buf.write_char(hex[byte.to_int() / 16].unsafe_to_char())
    buf.write_char(hex[byte.to_int() % 16].unsafe_to_char())
  }
  buf.to_string()
}
