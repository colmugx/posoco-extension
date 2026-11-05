///|
/// Status-segment publication: the policy owns the `permission` segment on
/// the session event channel and republishes it on mode switches.

///|
/// Records every `StatusChanged` op delivered on the session event channel.
priv struct RecordingStatus {
  ops : Array[@kit_events.StatusOp]
}

///|
fn RecordingStatus::RecordingStatus() -> RecordingStatus {
  { ops: [], }
}

///|
/// A policy wired to a fresh session event system, plus the recorder
/// subscribed on it before the policy publishes anything.
fn new_wired_policy(
  mode : @posoco-ext-permission.PermissionMode,
) -> (@posoco-ext-permission.PermissionPolicy, RecordingStatus) raise {
  let system = @posoco.EventSystem()
  let recorder = RecordingStatus::RecordingStatus()
  match
    system.subscribe(fn(envelope) {
      match @kit_events.status_changed_of(envelope) {
        Some(op) => recorder.ops.push(op)
        None => ()
      }
    }) {
    Ok(_) => ()
    Err(_) => abort("subscribe on the session event system failed")
  }
  let policy = @posoco-ext-permission.PermissionPolicy::PermissionPolicy(
    mode,
    events=Some(permission_capability(system)),
  )
  compose_with_ui(policy)
  (policy, recorder)
}

///|
fn compose_with_ui(
  policy : @posoco-ext-permission.PermissionPolicy,
) -> Unit raise @posoco.CompositionError {
  let model = @tk.ScriptedModel([])
  let ui = @posoco.NoopUiPort()
  (policy as &@posoco.Lifecycle).on_compose(
    @tk.tk_view(requires=[], model~, ui~),
  )
}

///|
fn expected_register(value : String, color : String?) -> @kit_events.StatusOp {
  @kit_events.StatusOp::Register(
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
async test "a policy without a capability composes and switches silently" {
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
