///|
async test "builtin: poteto-mode is compiled into PStack without asset files" {
  let pstack = Pstack::builtin(PstackFakeFs::new()).unwrap()
  let skill = pstack.catalog().find("poteto-mode").unwrap()
  assert_true(skill.body is Some(_))
  assert_true(skill.skill_md_path.has_prefix("builtin/"))
  assert_true(skill.body.unwrap().contains("Root-cause bug fixing"))
  assert_true(skill.body.unwrap().contains("Investigation"))
  assert_true(!pstack.is_mode_active())
}

///|
async test "builtin: discovery merges the PStack method into the host catalog" {
  let fs = PstackFakeFs::new()
  let options : @skills.SkillDiscoveryOptions = {
    ..@skills.SkillDiscoveryOptions::default(),
    include_repository: false,
    include_user: false,
  }
  let pstack = Pstack::discover(
    fs,
    cwd="/workspace",
    home="/home/test",
    discovery_options=options,
  ).unwrap()
  assert_true(pstack.catalog().find("poteto-mode") is Some(_))
}

///|
async test "statusbar: activation registers Mode On and shutdown unregisters it" {
  let system = @posoco.EventSystem()
  let envelopes : Array[@posoco.EventEnvelope] = []
  let _subscription = system.subscribe(fn(envelope) {
    envelopes.push(envelope)
  }).unwrap()
  let publisher = system.publisher(owner="posoco_ext_pstack").unwrap()
  let pstack = Pstack::builtin(
    PstackFakeFs::new(),
    events=Some(publisher),
  ).unwrap()

  match @posoco.CommandPort::invoke(pstack, "poteto-mode", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("activated skill: poteto-mode"))
    @posoco.CommandOutcome::Failure(reason~) => fail(reason)
    @posoco.CommandOutcome::NeedsInput(prompt~) => fail(prompt)
  }
  assert_true(pstack.is_mode_active())
  assert_eq(envelopes.length(), 1)
  assert_eq(@kit_events.publisher_id(envelopes[0]), Some("posoco_ext_pstack"))
  match @kit_events.status_changed_of(envelopes[0]) {
    Some(@kit_events.Register(segment~, label~, priority~, value~, color~)) => {
      assert_eq(segment, "🥔")
      assert_eq(label, None)
      assert_eq(priority, 5)
      assert_eq(value, Some("Mode On"))
      assert_eq(color, Some("success"))
    }
    _ => fail("expected PStack Mode On registration")
  }

  ignore(@posoco.CommandPort::invoke(pstack, "poteto-mode", Json::null()))
  assert_eq(envelopes.length(), 1)

  ignore(@posoco.CommandPort::invoke(pstack, "poteto-mode-off", Json::null()))
  assert_true(!pstack.is_mode_active())
  assert_eq(envelopes.length(), 2)
  match @kit_events.status_changed_of(envelopes[1]) {
    Some(@kit_events.Unregister(segment~)) => assert_eq(segment, "🥔")
    _ => fail("expected PStack status unregister")
  }

  ignore(@posoco.CommandPort::invoke(pstack, "poteto-mode", Json::null()))
  assert_eq(envelopes.length(), 3)
  await pstack.on_shutdown()
  assert_true(!pstack.is_mode_active())
  assert_eq(envelopes.length(), 4)
  match @kit_events.status_changed_of(envelopes[3]) {
    Some(@kit_events.Unregister(segment~)) => assert_eq(segment, "🥔")
    _ => fail("shutdown must clear PStack status")
  }
}
