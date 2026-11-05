///|
/// Collect this extension's status events independently of any host UI: a
/// fresh `EventSystem` subscribed to the closed `@kit_events.StatusChanged`
/// protocol events the toolchain publishes.
priv struct MbtxStatusRecorder {
  events : Array[@kit_events.StatusOp]
}

///|
fn MbtxStatusRecorder::MbtxStatusRecorder() -> MbtxStatusRecorder {
  { events: [], }
}

///|
/// Register a fresh system as the process default (the same hand-off the host
/// performs at assembly) and start capturing status operations.
fn capture_status_system(recorder : MbtxStatusRecorder) -> @posoco.EventSystem {
  let system = @posoco.EventSystem()
  @devkit.events_system_register(system)
  match
    system.subscribe(fn(envelope) {
      match @kit_events.status_changed_of(envelope) {
        Some(op) => recorder.events.push(op)
        None => ()
      }
    }) {
    Ok(_) => ()
    Err(_) => abort("subscribe on a fresh EventSystem failed")
  }
  system
}

///|
async test "mbtx publishes checking and unregisters on successful initialization" {
  let recorder = MbtxStatusRecorder::MbtxStatusRecorder()
  let _system = capture_status_system(recorder)
  let manager = @posoco-ext-mbtx.ToolchainManager()
  let first = manager.ensure_ready()
  assert_eq(first.origin, @posoco-ext-mbtx.ToolchainOrigin::System)
  assert_true(manager.status().contains("MBTX: ready"))
  assert_eq(recorder.events.length(), 2)
  assert_true(recorder.events[0] is @kit_events.Register(segment="mbtx", ..))
  assert_true(recorder.events[1] is @kit_events.Unregister(segment="mbtx"))
  let second = manager.ensure_ready()
  assert_eq(second.origin, first.origin)
  assert_eq(recorder.events.length(), 2)
}

///|
test "mbtx extension registers status command without eager provisioning" {
  let ext = @posoco-ext-mbtx.MbtxExtension()
  let manifest = ext.manifest()
  assert_eq(manifest.id, "posoco_ext_mbtx")
  assert_eq(manifest.commands.length(), 1)
  let commands = manifest.commands[0].commands()
  assert_eq(commands.length(), 1)
  assert_eq(commands[0].id, "mbtx")
}
