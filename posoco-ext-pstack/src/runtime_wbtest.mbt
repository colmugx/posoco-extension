///|
async test "workflow: activation and every supported playbook use native Skills resources" {
  let fs = PstackFakeFs::new()
  add_bundle_skill(fs)
  let options : @skills.SkillDiscoveryOptions = {
    ..@skills.SkillDiscoveryOptions::default(),
    include_repository: false,
    include_user: false,
  }
  let pstack = Pstack::discover(
    fs, cwd="/workspace", home="/home/test",
    assets_root="/bundle", discovery_options=options,
  ).unwrap()
  assert_true(pstack.catalog().find("poteto-mode").unwrap().body is None)
  match pstack.skills.activate_skill("poteto-mode") {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("Use the engineering workflow"))
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => fail(content)
    _ => fail("PStack SKILL.md should activate")
  }
  for name in ["investigation", "bug-fix", "feature", "refactoring", "perf-issue", "prototype"] {
    let path = "resources/upstream/skills/poteto-mode/playbooks/" + name + ".md"
    match pstack.skills.read_skill_resource("poteto-mode", path) {
      @posoco.ToolOutcome::Success(content~, ..) =>
        assert_true(content.contains("playbook"))
      @posoco.ToolOutcome::ToolReportedError(content~, ..) => fail(content)
      _ => fail("PStack playbook read should succeed")
    }
  }
  match pstack.skills.read_skill_resource("poteto-mode", "resources/posoco-harness.md") {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("Posoco runtime mapping"))
    _ => fail("Posoco adapter must be readable")
  }
  match pstack.skills.read_skill_resource("poteto-mode", "../outside.md") {
    @posoco.ToolOutcome::ToolReportedError(..) => ()
    _ => fail("resource containment must remain enforced")
  }
}

///|
async test "workflow: discovery rejects a missing required playbook" {
  let fs = PstackFakeFs::new()
  add_bundle_skill(fs)
  ignore(fs.files.remove(
    "/bundle/skills/poteto-mode/resources/upstream/skills/poteto-mode/playbooks/feature.md",
  ))
  let options : @skills.SkillDiscoveryOptions = {
    ..@skills.SkillDiscoveryOptions::default(),
    include_repository: false,
    include_user: false,
  }
  assert_true(
    Pstack::discover(
      fs, cwd="/workspace", home="/home/test",
      assets_root="/bundle", discovery_options=options,
    ) is None,
  )
}

///|
async test "statusbar: /poteto-mode toggles and shutdown clears the status" {
  let fs = PstackFakeFs::new()
  add_bundle_skill(fs)
  let system = @posoco.EventSystem()
  let envelopes : Array[@posoco.EventEnvelope] = []
  let _subscription = system.subscribe(fn(envelope) {
    envelopes.push(envelope)
  }).unwrap()
  let publisher = system.publisher(owner="posoco_ext_pstack").unwrap()
  let options : @skills.SkillDiscoveryOptions = {
    ..@skills.SkillDiscoveryOptions::default(),
    include_repository: false,
    include_user: false,
  }
  let pstack = Pstack::discover(
    fs, cwd="/workspace", home="/home/test", assets_root="/bundle",
    events=Some(publisher), discovery_options=options,
  ).unwrap()
  match @posoco.CommandPort::invoke(pstack, "poteto-mode", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("activated skill: poteto-mode"))
      assert_true(structured.unwrap().stringify().contains("agent_skill_activation"))
    }
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
    _ => fail("expected registration")
  }
  match @posoco.CommandPort::invoke(pstack, "poteto-mode", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("Poteto Mode Off"))
      assert_true(structured is None)
    }
    @posoco.CommandOutcome::Failure(reason~) => fail(reason)
    @posoco.CommandOutcome::NeedsInput(prompt~) => fail(prompt)
  }
  assert_true(!pstack.is_mode_active())
  assert_eq(envelopes.length(), 2)
  match @kit_events.status_changed_of(envelopes[1]) {
    Some(@kit_events.Unregister(segment~)) => assert_eq(segment, "🥔")
    _ => fail("expected unregister")
  }
  ignore(@posoco.CommandPort::invoke(pstack, "poteto-mode", Json::null()))
  assert_eq(envelopes.length(), 3)
  pstack.on_shutdown()
  assert_true(!pstack.is_mode_active())
  assert_eq(envelopes.length(), 4)
  match @kit_events.status_changed_of(envelopes[3]) {
    Some(@kit_events.Unregister(segment~)) => assert_eq(segment, "🥔")
    _ => fail("shutdown must clear status")
  }
}
