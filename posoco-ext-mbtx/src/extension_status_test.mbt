///|
/// Collect this extension's status events independently of any host UI.
priv struct MbtxStatusRecorder {
  events : Array[@devkit.StatusOp]
}

///|
impl @devkit.BusSubscriber for MbtxStatusRecorder with fn on_bus_event(
  self : MbtxStatusRecorder,
  event : @devkit.BusEvent,
) -> Unit {
  match @devkit.decode_status_op(event) {
    Some(op) => self.events.push(op)
    None => ()
  }
}

///|
async test "mbtx publishes checking and unregisters on successful initialization" {
  let bus = @devkit.EventBus()
  let recorder = MbtxStatusRecorder::{events: []}
  bus.subscribe(recorder)
  let manager = @posoco-ext-mbtx.ToolchainManager(bus=bus)
  let first = manager.ensure_ready()
  assert_eq(first.origin, @posoco-ext-mbtx.ToolchainOrigin::System)
  assert_true(manager.status().contains("MBTX: ready"))
  assert_eq(recorder.events.length(), 2)
  assert_true(recorder.events[0] is @devkit.StatusOp::Register(segment="mbtx", ..))
  assert_true(recorder.events[1] is @devkit.StatusOp::Unregister(segment="mbtx"))
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
