///|
/// Announce the persisted session id on the status bus. Re-registering on
/// every persist is intentional because later registrations are idempotent.
fn publish_session_status(bus : @devkit.EventBus?, id : String) -> Unit {
  match bus {
    Some(bus) =>
      @devkit.publish_status_register(
        bus,
        source="posoco_ext_fs_session",
        segment="session",
        priority=80,
        value=id,
      )
    None => ()
  }
}
