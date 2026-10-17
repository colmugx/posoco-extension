///|
/// A freshly attached backend settles its startup restore asynchronously and
/// answers every earlier query with `Initializing`. Recovery is exactly the
/// after-restart read, so the lookup waits out that one-time window instead
/// of failing; terminal restore failures still propagate immediately.
let recovery_poll_ms : Int32 = 20

///|
/// Wait budget for startup restore, aligned with the coordinator ask timeout.
let recovery_poll_attempts : Int32 = 250

///|
async fn settled_expansion_history(
  backend : @backend.BoardBackend,
) -> Result[Array[@domain.ExpansionRecord], ExpansionError] {
  for _ in 0..<recovery_poll_attempts {
    match backend.expansion_history() {
      Err(@coordinator.Initializing) => @async.sleep(recovery_poll_ms)
      result => return result.map_err(error => Backend(error))
    }
  }
  Err(Backend(@coordinator.Initializing))
}

///|
/// Read-only recovery: never resubmit a proposal, reallocate IDs, or change tasks.
/// A fresh host rejects every already-used proposal ID; callers inspect this
/// durable record to learn its whole-proposal outcome after process restart.
pub async fn recover_expansion(
  backend : @backend.BoardBackend,
  proposal_id : String,
) -> Result[@domain.ExpansionRecord?, ExpansionError] {
  let records = match settled_expansion_history(backend) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for record in records {
    if record.expansion_id.value == proposal_id {
      return Ok(Some(record))
    }
  }
  Ok(None)
}
