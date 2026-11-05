///|
/// Announce the persisted session id on the status channel. Re-registering on
/// every persist is intentional because later registrations are idempotent.
///
/// The op travels as `@kit_events.StatusChanged(@kit_events.Register(..))` —
/// the same closed payload the devkit `publish_status_*` helpers publish —
/// through the store's owner-bound capability, so the bridge renders the
/// segment exactly as before. A missing or closed channel is a silent no-op.
fn JsonlSessionStore::publish_session_status(
  self : JsonlSessionStore,
  id : String,
) -> Unit {
  match self.events {
    Some(events) => {
      let op : @kit_events.StatusOp = @kit_events.Register(
        segment="session",
        label=None,
        priority=80,
        value=Some(id),
        color=None,
      )
      ignore(events.publish(@kit_events.StatusChanged(op)))
    }
    None => ()
  }
}
