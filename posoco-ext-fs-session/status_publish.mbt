///|
/// status_publish.mbt — shared by both targets. After a successful persist,
/// the session id is announced on the devkit status bus so a status bar can
/// display the current session. Re-registering on every persist is
/// intentional: the bridge keeps the first register for a segment, so later
/// registers are idempotent there.
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
