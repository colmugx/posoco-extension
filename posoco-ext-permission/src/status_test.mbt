///|
/// Status-segment publication: the policy owns the `permission` segment on
/// the shared devkit status bus and republishes it on mode switches.

///|
/// Records every status op decoded off the bus.
priv struct RecordingStatus {
  ops : Array[@devkit.StatusOp]
}

///|
fn RecordingStatus::RecordingStatus() -> RecordingStatus {
  { ops: [], }
}

///|
impl @devkit.BusSubscriber for RecordingStatus with fn on_bus_event(
  self : RecordingStatus,
  event : @devkit.BusEvent,
) -> Unit {
  match @devkit.decode_status_op(event) {
    Some(op) => self.ops.push(op)
    None => ()
  }
}

///|
fn new_wired_policy(
  mode : @posoco-ext-permission.PermissionMode,
) -> (@posoco-ext-permission.PermissionPolicy, RecordingStatus) raise {
  let bus = @devkit.EventBus()
  let recorder = RecordingStatus::RecordingStatus()
  bus.subscribe(recorder as &@devkit.BusSubscriber)
  let policy = @posoco-ext-permission.PermissionPolicy::PermissionPolicy(
    mode,
    bus=Some(bus),
  )
  compose_with_ui(policy)
  (policy, recorder)
}

///|
fn compose_with_ui(
  policy : @posoco-ext-permission.PermissionPolicy,
) -> Unit raise @posoco.CompositionError {
  let model = @posoco.ScriptedModel([])
  let ui = @posoco.NoopUiPort()
  (policy as &@posoco.Lifecycle).on_compose(
    @posoco.tk_view(requires=[], model~, ui~),
  )
}

///|
fn expected_register(value : String, color : String?) -> @devkit.StatusOp {
  @devkit.StatusOp::Register(
    segment="permission",
    label=None,
    priority=10,
    value=Some(value),
    color~,
  )
}

///|
test "compose publishes the current mode as the permission segment" {
  let (_, recorder) = new_wired_policy(WorkspaceWrite)
  assert_eq(recorder.ops, [expected_register("workspace_write", None)])
}

///|
test "yolo composes with the warning color, readonly with info" {
  let (_, yolo) = new_wired_policy(Yolo)
  assert_eq(yolo.ops, [expected_register("yolo", Some("warning"))])
  let (_, read_only) = new_wired_policy(ReadOnly)
  assert_eq(read_only.ops, [expected_register("readonly", Some("info"))])
}

///|
async test "a successful mode switch republishes the segment" {
  let (policy, recorder) = new_wired_policy(WorkspaceWrite)
  match
    @posoco.CommandPort::invoke(policy, "permission", Json::string("yolo")) {
    @posoco.CommandOutcome::Success(..) => ()
    _ => fail("expected the switch to succeed")
  }
  assert_eq(recorder.ops, [
    expected_register("workspace_write", None),
    expected_register("yolo", Some("warning")),
  ])
}

///|
async test "a refused switch publishes nothing" {
  let (policy, recorder) = new_wired_policy(WorkspaceWrite)
  match
    @posoco.CommandPort::invoke(policy, "permission", Json::string("bogus")) {
    @posoco.CommandOutcome::Failure(..) => ()
    _ => fail("expected the switch to be refused")
  }
  assert_eq(recorder.ops, [expected_register("workspace_write", None)])
}

///|
async test "a policy without a bus composes and switches silently" {
  let policy = @posoco-ext-permission.PermissionPolicy::PermissionPolicy(
    WorkspaceWrite,
  )
  compose_with_ui(policy)
  match
    @posoco.CommandPort::invoke(policy, "permission", Json::string("readonly")) {
    @posoco.CommandOutcome::Success(..) => ()
    _ => fail("expected the switch to succeed")
  }
}
